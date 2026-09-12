# 08-html-rendering — MailHTML sanitizer, ThreadDocument template, WebViewHost, cid handler, link policy

Module 08 of `docs/plan/design/modules.md`. Sources of truth: `architecture.md` §2.3 (`MailHTML` interface), §2.2 "Render/ThreadDocument.swift", §2.4 "Web" block, §9 (HTML rendering, verbatim template and configuration), §4.5 (how `SyncEngine` calls the sanitizer), §7.2 (how `ComposeModel` calls `QuoteExtractor`), §7.5 (`SignatureSanitizer`), §10 (theme tokens reaching the template), §12.2 step 3c (`WebViewHost.prepare()` +1 s), §13.2/§13.3 (tests), §14 #3/#4/#5/#26 (UNVERIFIED items with fallbacks). Research: `[html-rendering §1–§4, §6, §7]`, `[ios-platform §4]`, `[mime-rfc §5.4]`, `[gmail-api §6]`.

Depends on: **02-mailcore-mime** (`PlainTextHTML.convert`, `OutgoingBodies.escape`), **05-gmail-client** (`GmailClient.getAttachment`, `GmailClient.getMessage`, `GmailError`, `RequestLimiter`), **06-storage** (`SanitizedBody`, `DarkStrategy`, `AttachmentRecord`, `BodyRepository.attachment`, `BodyRepository.updateAttachmentIds`, `TestDatabase`), and transitively **03-mailcore-gmail-model** via 05 (`MessageParser.parse`, `ParsedAttachment`, `GmailMessage`) and **01-project-setup** (`ThemeCSSTokens`, `SystemPalette`, `ThemeStore`, `Log`, `AppEnvironment`, `Settings.loadRemoteImages`).

---

## 1. Purpose & scope

### 1.1 In scope

1. `MailHTML` library (imports `MailCore` + `SwiftSoup`): the allowlist sanitizer pipeline of architecture §9.1 (`Sanitizer`, `StyleScrubber`, `TrackingPixel`, `DarkStrategyClassifier`), the signature sanitizer (`SignatureSanitizer`), and the quote extractor that turns a cached sanitized fragment back into quotable outgoing HTML (`QuoteExtractor`).
2. `MailCore` file `Render/ThreadDocument.swift`: the pure string builder that renders one thread (subject + N message sections) into one self-contained HTML document with the CSS of architecture §9.2 (CSS variables from theme tokens, `@media (prefers-color-scheme)` and `html[data-theme]` selectors, per-message dark strategy classes), the two CSP variants, the per-body and per-document size caps, the warm-up/recycle `empty` document and the `toggleScript`.
3. App `Web/` folder: the single pooled `WKWebView` and its configuration factory (`WebViewHost`), content rule lists (`RuleLists`: JSON, compile-or-lookup, swap), warm-up/recycle, the throwaway instance for the signature preview, the `UIViewRepresentable` wrapper (`MailWebView`), the JS→Swift tap bridge (`WebBridge`, `WebMessage`, the click-delegate user script), the `minimail-cid` URL scheme handler (`CIDSchemeHandler`) backed by an actor that caches inline images and fetches them through `attachments.get` with one re-resolve on 404, a 2-in-flight cap and a 60 s failure cache (`InlineImageStore`), and the navigation policy that cancels every navigation and hands links to the system (`LinkPolicy`).
4. The `[08]` insertions in `AppEnvironment` (construction of `InlineImageStore`, `WebBridge`, `WebViewHost`; `startDeferredWork` step c; wipe tail).
5. Tests: `MailHTMLTests` (sanitizer, scrubber, tracking pixels, classifier, signature sanitizer, quote extractor, performance case) with the `Fixtures/html/*` catalog of architecture §13.2, `ThreadDocumentTests` in `MailCoreTests`, and the app tests `WebViewHostTests`, `WebBridgeTests`, `InlineImageStoreTests`.

### 1.2 Explicitly out of scope

- `SanitizedBody` and `DarkStrategy` declarations — module 06 created `Packages/MailCore/Sources/MailHTML/SanitizedBody.swift` (06 D2). This module never redefines them.
- `ThemeCSSTokens` — module 01 created `Packages/MailCore/Sources/MailCore/Render/ThemeCSSTokens.swift` (01 D2). Not redefined here.
- Calling the sanitizer (07 `SyncEngine.prepareBody`), calling `QuoteExtractor` (11 `ComposeModel.makeDraft`), calling `SignatureSanitizer` (13 `SignatureEditorScreen`), building `ThreadDocumentMessage`s from `ThreadDetail` and deciding when to reload (10 `ThreadModel`), the thread screen, bottom toolbar, QuickLook, `AttachmentOpener` (10), the signature editor screen (13).
- Any SQL string. The only database access is `AttachmentRecord` fetched with GRDB's query interface and `BodyRepository.updateAttachmentIds` inside `InlineImageStore` (§4.9).
- `Maintenance.purgeFiles` (07) purges `Caches/cid` by age; this module only writes there and wipes it on sign-out.
- Network code other than `GmailClient.getAttachment` / `GmailClient.getMessage` calls from `InlineImageStore` (architecture §2.1 rule 2 exception).

### 1.3 Consumers and what they take from this module

| Consumer | Symbols used |
|---|---|
| 07 `SyncEngine.prepareBody` | `Sanitizer.sanitize(html:messageId:)`, `Sanitizer.fromPlainText(_:)`, `Sanitizer.version`, `Sanitizer.maxInputBytes`, `SanitizerError` |
| 10 `ThreadScreen` / `ThreadModel` | `ThreadDocument.render`, `ThreadDocument.strippedIds`, `ThreadDocument.toggleScript`, `ThreadDocumentMessage`, `ThreadDocumentAttachment`, `MailWebView`, `WebViewHost.{webView,setImagesAllowed,load,recycle,didLeaveThread,linkPolicy}`, `WebBridge.onMessage`, `WebMessage`, `LinkPolicy.openURL`, `Log.Interval.documentLoad` (ended by `LinkPolicy.onDidFinish`) |
| 11 `ComposeModel.makeDraft` | `QuoteExtractor.quotable(_:)` |
| 13 `SignatureEditorScreen` | `SignatureSanitizer.sanitize(_:)`, `SignatureSanitizer.hasDataImages(_:)`, `WebViewHost.makeThrowawayWebView()`, `ThreadDocument.empty` is NOT used there (13 wraps the signature in its own minimal document; see §10 A9) |
| 01/07 `AppEnvironment` | `InlineImageStore`, `CIDSchemeHandler`, `WebBridge`, `WebViewHost.prepare()`, `InlineImageStore.purge()` |
| 14 QA | `WebViewHostTests` conventions, fixture catalog `Fixtures/html/*`, device-checklist items listed in §9 |

---

## 2. Files

| Path (repo root) | Kind | Purpose |
|---|---|---|
| `Packages/MailCore/Sources/MailHTML/Sanitizer.swift` | new | `SanitizerError`, `Sanitizer` (size guard, image pass, classify, `SwiftSoup.clean` with `Sanitizer.whitelist()`, scrub, `fromPlainText`) |
| `Packages/MailCore/Sources/MailHTML/StyleScrubber.swift` | new | `StyleScrubber.patterns`, `StyleScrubber.scrub` (NSRegularExpression pass) |
| `Packages/MailCore/Sources/MailHTML/TrackingPixel.swift` | new | `TrackingPixel.isTracking(_:src:)` heuristic + pixel parsers |
| `Packages/MailCore/Sources/MailHTML/DarkStrategyClassifier.swift` | new | `DarkStrategyClassifier.classify(_:sawBackgroundAttribute:)` |
| `Packages/MailCore/Sources/MailHTML/SignatureSanitizer.swift` | new | `SignatureSanitizer.sanitize`, `hasDataImages`, `signatureWhitelist()` |
| `Packages/MailCore/Sources/MailHTML/QuoteExtractor.swift` | new | `QuoteExtractor.quotable(_:)` |
| `Packages/MailCore/Sources/MailHTML/MailHTMLPackage.swift` | unchanged | 01's placeholder stays (its smoke test references it); nothing here depends on it |
| `Packages/MailCore/Sources/MailCore/Render/ThreadDocument.swift` | new | `ThreadDocumentAttachment`, `ThreadDocumentMessage`, `ThreadDocument` (template, CSS, caps, `empty`, `toggleScript`, `strippedIds`, `placeholderGIF`) |
| `Packages/MailCore/Tests/MailCoreTests/ThreadDocumentTests.swift` | new | CSP variants, `data-theme`, sections/classes, `data-src` restore, caps, escaping, `toggleScript`, `empty` |
| `Packages/MailCore/Tests/MailHTMLTests/Support/HTMLFixtures.swift` | new | `HTMLFixtures.load(_ name: String) -> String` from `Bundle.module` (`Fixtures/html/<name>.html`) |
| `Packages/MailCore/Tests/MailHTMLTests/SanitizerTests.swift` | new | pipeline, XSS samples, images, cid, size guard, malformed input, fromPlainText, performance |
| `Packages/MailCore/Tests/MailHTMLTests/StyleScrubberTests.swift` | new | each pattern, `data:` url kept, case-insensitivity |
| `Packages/MailCore/Tests/MailHTMLTests/TrackingPixelTests.swift` | new | heuristic matrix |
| `Packages/MailCore/Tests/MailHTMLTests/DarkStrategyClassifierTests.swift` | new | plain/card/native matrix |
| `Packages/MailCore/Tests/MailHTMLTests/SignatureSanitizerTests.swift` | new | keeps https img, drops script/javascript:, `hasDataImages` |
| `Packages/MailCore/Tests/MailHTMLTests/QuoteExtractorTests.swift` | new | `data-src` restore, cid `<img>` removal, `mm-*` class removal, never throws |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/newsletter.html` | new | table-and-images newsletter with `<style>`, `bgcolor`, `@import`, tracking pixel, `<script>` (§5.9) |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/plain-mail.html` | new | Gmail-style `<div dir="ltr">` mail, no backgrounds, one grey `span`, one link |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/dark-native.html` | new | declares `color-scheme: light dark` + `prefers-color-scheme` rules + backgrounds |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/tracking-pixels.html` | new | nine `<img>` variants in the §4.3 matrix order (§5.9) |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/malformed.html` | new | `<!--[if mso]>`, unclosed tags, mis-nesting, stray `<` |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/inline-cid.html` | new | three `cid:` spellings + one remote + one data image |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/signature.html` | new | signature with https logo, data image, script, `javascript:` link |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/xss-samples.html` | new | 18 numbered attack vectors (§5.9) |
| `minimail/Web/WebViewHost.swift` | new | `RuleLists`, `WebViewHost` (configuration factory, pooled instance, prepare/warm, images swap, recycle, throwaway) |
| `minimail/Web/MailWebView.swift` | new | `MailWebView` (`UIViewRepresentable`), `MailWebContainerView` |
| `minimail/Web/WebBridge.swift` | new | `WebMessage`, `WebBridge` (`WKScriptMessageHandler`, `clickDelegateJS`, `parse`) |
| `minimail/Web/CIDSchemeHandler.swift` | new | `CIDSchemeHandler` (`WKURLSchemeHandler`, stopped-task tracking, URL parsing) |
| `minimail/Web/InlineImageStore.swift` | new | `InlineImageStore` actor, `InlineImageError`, memory/disk cache, fetch with re-resolve, in-flight cap, failure cache |
| `minimail/Web/LinkPolicy.swift` | new | `LinkPolicy` (`WKNavigationDelegate` + `WKUIDelegate`), pure `decision(for:type:)` |
| `minimail/App/AppEnvironment.swift` | modify | `[08]` insertion: `inlineImages`, `webBridge`, `webHost` properties + construction; `cidCacheDirectory`; `startDeferredWork` step c; wipe tail |
| `minimailTests/Web/WebViewHostTests.swift` | new | configuration flags, rule-list JSON compiles, swap state, throwaway instance, warm-up load, recycle |
| `minimailTests/Web/WebBridgeTests.swift` | new | `WebBridge.parse` matrix, `clickDelegateJS` content, `LinkPolicy.decision` matrix, `CIDSchemeHandler.parse` |
| `minimailTests/Web/InlineImageStoreTests.swift` | new | cache hit/miss, re-resolve on 404, failure cache, in-flight cap, unknown cid, purge |

Files listed in architecture §1.3 under `minimail/Web/` are all created here. `minimailTests/Web/WebBridgeTests.swift` and `InlineImageStoreTests.swift` are ADDITIONS to the §1.3 tree (see §10 D7).

---

## 3. Public interface

Every `MailHTML`/`MailCore` declaration is `nonisolated` by package default and `Sendable` where stated. App-target types are `@MainActor` by the project default unless marked `nonisolated` or `actor`.

### 3.1 `MailHTML` — `Sanitizer.swift`

```swift
import Foundation
import MailCore
import SwiftSoup

/// Thrown by `Sanitizer.sanitize` and `SignatureSanitizer.sanitize`. SwiftSoup's own errors propagate unchanged.
public enum SanitizerError: Error, Equatable, Sendable {
    /// `html.utf8.count > Sanitizer.maxInputBytes`. The caller (07) falls back to `fromPlainText`.
    case tooLarge(bytes: Int)
    /// `SwiftSoup.clean` returned nil (no body). The caller treats it like any SwiftSoup error.
    case cleanFailed
}

public enum Sanitizer {
    /// Bump when the pipeline output changes; 07 re-fetches bodies whose `message_body.sanitizerVersion < version` lazily on open.
    public static let version: Int = 1
    /// 2 MiB; larger input throws `.tooLarge` before parsing.
    public static let maxInputBytes = 2_097_152
    /// 1×1 transparent GIF data URI; identical to `ThreadDocument.placeholderGIF` (single definition lives in MailCore).
    public static let placeholderGIF: String = ThreadDocument.placeholderGIF
    /// Architecture §9.1 steps 1–7 (§4.1 of this spec). `messageId` is the Gmail message id used in `minimail-cid://<messageId>/<cid>` URLs.
    /// Throws `SanitizerError.tooLarge`, `SanitizerError.cleanFailed`, or any error thrown by SwiftSoup. Never returns raw (uncleaned) HTML.
    public static func sanitize(html: String, messageId: String) throws -> SanitizedBody
    /// `SanitizedBody(html: PlainTextHTML.convert(text), hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: [])`.
    public static func fromPlainText(_ text: String) -> SanitizedBody
    /// The exact whitelist of §5.1 (builds a fresh `Whitelist` each call; `Whitelist` is a class and not `Sendable`).
    public static func whitelist() throws -> Whitelist
    /// The allowed inline-CSS property names of §5.1 (shared with `SignatureSanitizer`).
    public static let allowedCSSProperties: [String]
    /// The `OutputSettings` used for every `html()` / `clean()` call: `prettyPrint(pretty: false)` so no whitespace is inserted.
    static func outputSettings() -> OutputSettings
}
```

### 3.2 `MailHTML` — `StyleScrubber.swift`

```swift
import Foundation

public enum StyleScrubber {
    /// Regex sources (ICU, case-insensitive) of §5.2, applied in order to the whole cleaned fragment.
    public static let patterns: [String]
    /// Removes every match of every pattern (replacement ""). Pure; never throws (patterns are compiled once; a compile failure is a programmer error → `preconditionFailure`).
    public static func scrub(_ html: String) -> String
}
```

### 3.3 `MailHTML` — `TrackingPixel.swift`

```swift
import Foundation
import SwiftSoup

public enum TrackingPixel {
    /// `[html-rendering §1.5]` rule: remote (`http://`/`https://`) AND `alt` empty AND (tiny OR hidden). Never true for `cid:`/`data:` images.
    /// tiny = width ≤ 2 or height ≤ 2 (attribute first, then inline `style` declaration); hidden = `display:none` | `visibility:hidden` | `opacity:0`.
    public static func isTracking(_ img: Element, src: String) -> Bool
    /// "12", "12px", " 12 " → 12; "50%", "auto", "", non-numeric → nil.
    public static func pixels(_ attributeValue: String) -> Int?
    /// Parses `style` as `;`-separated declarations; returns `pixels(value)` of the declaration whose name (trimmed, lowercased) equals `property` exactly (`min-width` does not match `width`). Last matching declaration wins.
    public static func cssPixels(style: String, property: String) -> Int?
}
```

### 3.4 `MailHTML` — `DarkStrategyClassifier.swift`

```swift
import Foundation
import SwiftSoup

public enum DarkStrategyClassifier {
    /// `[html-rendering §3.3]`: declares `prefers-color-scheme` / `color-scheme:` / `supported-color-schemes` → `.native`;
    /// any author background (`background(-color): <not transparent|none|inherit>`, `bgcolor=`, or `sawBackgroundAttribute`)
    /// or (≥ 3 `img` and ≥ 2 `table`) → `.card`; else `.plain`. Inspects `doc.body()?.html()` lowercased. Never throws (SwiftSoup errors → `.plain`).
    public static func classify(_ doc: Document, sawBackgroundAttribute: Bool = false) -> DarkStrategy
    /// ICU source of the background test: `background(-color)?\s*:\s*(?!transparent|none|inherit)`.
    public static let backgroundPattern: String
}
```

### 3.5 `MailHTML` — `SignatureSanitizer.swift`

```swift
import Foundation
import MailCore
import SwiftSoup

public enum SignatureSanitizer {
    /// Same allowlist as `Sanitizer` but `img[src]` protocols `http`, `https`, `data` are kept as-is (no placeholders, no `data-src`);
    /// `cid:` and other schemes lose their `src`; `srcset`/`sizes`/`loading`/`background` removed; `StyleScrubber` applied; result trimmed.
    /// Throws `SanitizerError.tooLarge` (> `Sanitizer.maxInputBytes`), `.cleanFailed`, or SwiftSoup errors.
    public static func sanitize(_ html: String) throws -> String
    /// `true` when the (raw or sanitized) HTML contains an `<img>` whose `src` starts with `data:` (case-insensitive). Module 13 shows the "Gmail does not render data: images" warning `[mime-rfc §3.4]`. Never throws (parse failure → substring test on `src="data:`).
    public static func hasDataImages(_ html: String) -> Bool
    /// `Sanitizer.whitelist()` with `addProtocols("img", "src", "http", "https", "data")` and without `img[data-src]`.
    public static func signatureWhitelist() throws -> Whitelist
}
```

### 3.6 `MailHTML` — `QuoteExtractor.swift`

```swift
import Foundation
import MailCore
import SwiftSoup

public enum QuoteExtractor {
    /// Sanitized fragment (a `message_body.bodyHtml` value) → quotable outgoing HTML (§4.5):
    /// `img[data-src]` → `src = data-src`, `data-src` removed; `img[src^="minimail-cid:"]` REMOVED; every `mm-*` class token removed
    /// (empty `class` attribute dropped). Never throws: on any SwiftSoup error the input is returned unchanged. Output trimmed.
    public static func quotable(_ sanitizedHTML: String) -> String
}
```

### 3.7 `MailCore` — `Render/ThreadDocument.swift`

```swift
import Foundation

/// DEVIATION D1: named struct instead of the architecture's tuple element `(partId:filename:sizeLabel:)` so `ThreadDocumentMessage` can
/// synthesize `Equatable`/`Sendable` (tuples cannot).
public struct ThreadDocumentAttachment: Sendable, Equatable {
    public var partId: String
    public var filename: String
    public var sizeLabel: String          // caller-formatted ("1.5 MB"; app uses `Formatters.bytes`)
    public init(partId: String, filename: String, sizeLabel: String)
}

/// One message section. Field list verbatim from architecture §2.2 except `attachments` (D1).
public struct ThreadDocumentMessage: Sendable, Equatable {
    public var id: String
    public var fromName: String
    public var fromAddr: String
    public var toLine: String
    public var ccLine: String?
    public var dateLabel: String          // "14:32", "Yesterday", …
    public var dateFull: String           // full date for the `title` attribute
    public var snippet: String
    public var isUnread: Bool
    public var expanded: Bool
    public var bodyHTML: String?          // sanitized fragment; nil → skeleton "Loading…"
    public var bodyState: Int             // 0 loading, 1 cached, 2 unavailable
    public var darkStrategy: String       // "plain" | "card" | "native" (DarkStrategy.rawValue)
    public var hasRemoteImages: Bool
    public var imagesAllowed: Bool        // restore data-src → src for THIS message
    public var attachments: [ThreadDocumentAttachment]
    public init(id: String, fromName: String, fromAddr: String, toLine: String, ccLine: String?, dateLabel: String, dateFull: String,
                snippet: String, isUnread: Bool, expanded: Bool, bodyHTML: String?, bodyState: Int, darkStrategy: String,
                hasRemoteImages: Bool, imagesAllowed: Bool, attachments: [ThreadDocumentAttachment])
}

public enum ThreadDocument {
    /// Per body: bodies larger than this are cut at a UTF-8 boundary and followed by `<p class="mm-skeleton">Message truncated</p>`.
    public static let maxBodyBytes = 1_500_000
    /// Whole document: while the sum of rendered bodies exceeds this, the oldest collapsed messages keep only their snippet (`strippedIds`).
    public static let maxDocumentBytes = 6_000_000
    /// "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    public static let placeholderGIF: String
    /// Architecture §9.2 template. `messages` in display order (oldest first, as `Queries.threadDetail` returns them).
    /// `forcedScheme` "light" | "dark" | nil → `html[data-theme]`. `imagesAllowed` (document level) adds `https:` to the CSP `img-src`;
    /// per-message `imagesAllowed` restores `data-src` → `src` in that body only. Pure string building; never throws.
    public static func render(subject: String, messages: [ThreadDocumentMessage], light: ThemeCSSTokens, dark: ThemeCSSTokens,
                              forcedScheme: String?, imagesAllowed: Bool) -> String
    /// Same head/CSS with an empty `<body>` (warm-up and recycle). CSP = images-off variant.
    public static func empty(light: ThemeCSSTokens, dark: ThemeCSSTokens) -> String
    /// JS that toggles `mm-collapsed`/`mm-expanded` on `section.mm-msg[data-id="<id>"]` (§5.6). `messageId` characters outside `[A-Za-z0-9_-]` are dropped.
    public static func toggleScript(messageId: String) -> String
    /// ADDITION: the ids whose bodies `render` replaces by the "Tap to load" skeleton under the document cap, for the same input. Module 10 rebuilds + reloads when a stripped section is toggled open.
    public static func strippedIds(messages: [ThreadDocumentMessage]) -> Set<String>
    /// ADDITION: the `<style>` contents (§5.5) for the given tokens — exposed for tests and for the signature preview document (13).
    public static func css(light: ThemeCSSTokens, dark: ThemeCSSTokens) -> String
    /// ADDITION: the CSP `content` value: images off → `default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`; images on → `img-src data: minimail-cid: https:`.
    public static func csp(imagesAllowed: Bool) -> String
    /// ADDITION: body with `data-src` restored (§4.6 step 4); exposed for tests.
    public static func restoringRemoteImages(_ bodyHTML: String) -> String
}
```

### 3.8 App — `Web/WebBridge.swift`

```swift
import Foundation
import WebKit

/// Taps inside the document, delivered by the click-delegate user script. `.link` is never produced by `WebBridge` (links navigate and reach
/// `LinkPolicy.openURL`); the case exists so `ThreadModel` (10) can funnel `openURL` into the same switch. DEVIATION D2: `retry` added (template has `data-action="retry"`).
enum WebMessage: Equatable, Sendable {
    case toggle(messageId: String)
    case loadImages(messageId: String)
    case attachment(messageId: String, partId: String)
    case link(URL)
    case retry(messageId: String)
}

final class WebBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "mm"
    /// The delegated click listener of §5.7; injected `.atDocumentEnd`, `forMainFrameOnly: true` by `WebViewHost.makeConfiguration`.
    static let clickDelegateJS: String
    /// Set by the thread screen (10); default `{ _ in }`. Called on the main actor.
    var onMessage: (WebMessage) -> Void
    override init()
    /// `{action, id, part}` dictionary → `WebMessage` (§4.7); nil for anything else.
    static func parse(_ body: Any) -> WebMessage?
    /// `minimail-action://<action>/<id>[/<part>]` → `WebMessage` (fallback path when user scripts do not run, §10 F1).
    static func parse(actionURL url: URL) -> WebMessage?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage)
}
```

### 3.9 App — `Web/LinkPolicy.swift`

```swift
import Foundation
import UIKit
import WebKit

/// Navigation delegate of the pooled instance (and, with `openURL = { _ in }`, of throwaway instances). Cancels every navigation except the
/// `about:blank` load of `loadHTMLString`; `.linkActivated` with scheme http/https/mailto/tel → `openURL`; `minimail-action:` links → `onAction`.
final class LinkPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Set by the thread screen (10) to `openURL(url)` of `@Environment(\.openURL)`. Default `{ _ in }`.
    var openURL: (URL) -> Void
    /// ADDITION: receives `WebBridge.parse(actionURL:)` results (fallback F1). Default nil.
    var onAction: ((WebMessage) -> Void)?
    /// ADDITION: called from `webView(_:didFinish:)`; `WebViewHost` uses it to end the `documentLoad` signpost. Default nil.
    var onDidFinish: (() -> Void)?
    override init()
    /// Pure decision table (§4.8), unit-tested without a `WKNavigationAction`.
    static func decision(for url: URL?, type: WKNavigationType) -> (policy: WKNavigationActionPolicy, open: URL?, action: WebMessage?)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error)
    /// `WKUIDelegate`: new-window requests (target=_blank, window.open) → nil (nothing opens); the URL is handed to `openURL` when its scheme is http/https.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
}
```

### 3.10 App — `Web/CIDSchemeHandler.swift`

```swift
import Foundation
import WebKit

/// Serves `minimail-cid://<messageId>/<percent-encoded contentId>` from `InlineImageStore`. WebKit calls start/stop on the main thread.
/// Tracks the tasks it still owns; a task that was stopped never receives `didReceive`/`didFinish`/`didFailWithError`.
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "minimail-cid"
    let store: InlineImageStore
    init(store: InlineImageStore)
    /// `(host, percent-decoded path without the leading "/")`; nil when host or path is empty or decoding fails.
    static func parse(_ url: URL) -> (messageId: String, contentId: String)?
    /// Number of tasks currently in flight (tests).
    var activeCount: Int { get }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask)
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask)
}
```

### 3.11 App — `Web/InlineImageStore.swift`

```swift
import CryptoKit
import Foundation
import GRDB
import MailCore

enum InlineImageError: Error, Equatable, Sendable {
    case unknownContentId          // no attachment row with that contentId for the message (after one re-resolve)
    case recentlyFailed            // same key failed < 60 s ago; no network was touched
    case noBytes                   // attachments.get answered but the part has neither attachmentId nor inline data
}

/// Inline-image bytes for the cid scheme handler. Memory cache → disk cache → `attachments.get` (stored id, one re-resolve on 404),
/// at most 2 network fetches in flight, failures cached 60 s. DEVIATION D3: `db` is `any DatabaseWriter` (07 D1) so tests pass a `DatabaseQueue`.
actor InlineImageStore {
    static let maxInFlight = 2
    static let failureTTL: TimeInterval = 60
    static let memoryBudgetBytes = 8_000_000
    init(gmail: GmailClient, db: any DatabaseWriter, cacheDirectory: URL, clock: @Sendable () -> Date = Date.init)
    /// `(bytes, mimeType)`; mimeType from the attachment row (`"application/octet-stream"` when empty). Throws `InlineImageError`, `GmailError`, `DatabaseError`, `CancellationError`.
    func bytes(messageId: String, contentId: String) async throws -> (Data, String)
    /// Deletes `cacheDirectory` recursively, clears memory and failure caches. Called on sign-out (wipe tail).
    func purge() async
    /// Tests: `cacheDirectory/<messageId>/<sha1hex(contentId)>.bin`.
    nonisolated static func cacheFileURL(root: URL, messageId: String, contentId: String) -> URL
    /// Tests: number of entries currently in the failure cache (not yet expired).
    var failureCount: Int { get }
}
```

### 3.12 App — `Web/WebViewHost.swift`

```swift
import Foundation
import MailCore
import UIKit
import WebKit

/// Compiled content rule lists (`[html-rendering §2.2]`). Static state on the main actor; `prepare()` is idempotent.
enum RuleLists {
    static let blockAllIdentifier = "minimail.block-all.v1"
    static let imagesOnlyIdentifier = "minimail.images-only.v1"
    static let blockAllJSON: String            // §5.3, byte-exact
    static let imagesOnlyJSON: String          // §5.3, byte-exact
    static var blockAll: WKContentRuleList?
    static var imagesOnly: WKContentRuleList?
    /// Look up by identifier, else compile (`WKContentRuleListStore.default()`); failures logged (`web.rulelist.failed`) and leave the var nil.
    static func prepare() async
    /// Tests: `blockAll = nil; imagesOnly = nil`.
    static func reset()
}

/// Owner of the ONE pooled `WKWebView` (architecture decision 9). Created lazily on first access to `webView` or in `prepare()`.
final class WebViewHost {
    static let recycleDelay: TimeInterval = 60
    let cid: CIDSchemeHandler
    let bridge: WebBridge
    /// ADDITION: navigation/UI delegate of the pooled instance (strongly held here because WKWebView holds its delegates weakly).
    let linkPolicy: LinkPolicy
    private(set) var isPrepared: Bool
    private(set) var imagesAllowed: Bool          // which rule list is attached
    private(set) var isAttached: Bool             // a `MailWebView` currently hosts the instance
    private(set) var loadedRevision: Int          // -1 until the first `load(document:revision:)`
    init(cid: CIDSchemeHandler, bridge: WebBridge)
    /// Lazily created with `makeConfiguration(cid:bridge:)` and the instance settings of §4.10.
    var webView: WKWebView { get }
    /// `RuleLists.prepare()` → create the instance (adding `blockAll` to a pre-existing controller) → register the memory-warning observer → warm up with `ThreadDocument.empty`. Idempotent.
    func prepare() async
    /// `removeAllContentRuleLists()` + `add(allowed ? imagesOnly : blockAll)` (when compiled). Must be called BEFORE the load that needs it. No-op when the state already matches.
    func setImagesAllowed(_ allowed: Bool)
    /// ADDITION: `cancelScheduledRecycle()`, `Log.begin(.documentLoad)`, `webView.loadHTMLString(document, baseURL: nil)`, `loadedRevision = revision`.
    func load(document: String, revision: Int)
    /// Loads `ThreadDocument.empty` (drops the DOM, keeps the WebContent process); `loadedRevision = -1`; `setImagesAllowed(false)`.
    func recycle()
    /// ADDITION: schedules `recycle()` after `recycleDelay` unless a `load` or attach happens first (§4.10). 10 calls it on disappear.
    func didLeaveThread()
    /// Called by `MailWebView` (make/dismantle).
    func didAttach()
    func didDetach()
    /// Architecture §9.3 verbatim (§4.10 step list).
    static func makeConfiguration(cid: CIDSchemeHandler, bridge: WebBridge) -> WKWebViewConfiguration
    /// Signature preview only (13): same flags, block-all list, NO cid handler, NO message handler, NO user script; delegate = a `LinkPolicy` that opens nothing.
    func makeThrowawayWebView() -> WKWebView
}
```

### 3.13 App — `Web/MailWebView.swift`

```swift
import SwiftUI
import UIKit
import WebKit

/// Hosts the pooled instance inside a container view (the instance is re-parented on every appear). DEVIATION D4: `imagesAllowed` and
/// `backgroundColor` added to the architecture's field list so the rule-list swap and the background colour are applied before the load.
struct MailWebView: UIViewRepresentable {
    let host: WebViewHost
    let document: String
    let revision: Int                     // increments → reload
    let interfaceStyle: UIUserInterfaceStyle   // ThemeStore.interfaceStyle
    let imagesAllowed: Bool               // document-level flag passed to ThreadDocument.render
    let backgroundColor: UIColor          // UIColor(themeTokens.background)
    func makeUIView(context: Context) -> MailWebContainerView
    func updateUIView(_ container: MailWebContainerView, context: Context)
    static func dismantleUIView(_ container: MailWebContainerView, coordinator: Coordinator)
    func makeCoordinator() -> Coordinator
    final class Coordinator { var appliedRevision: Int = -1; var appliedStyle: UIUserInterfaceStyle = .unspecified }
}

/// Plain `UIView` whose single subview (the pooled web view) is pinned to its bounds in `layoutSubviews`.
final class MailWebContainerView: UIView {
    func host(_ webView: WKWebView)       // addSubview if not already a subview (re-parents from a previous container)
}
```

### 3.14 App — `App/AppEnvironment.swift` additions (`[08]`)

```swift
// stored properties added to AppEnvironment
let inlineImages: InlineImageStore
let webBridge: WebBridge
let webHost: WebViewHost
/// `Caches/cid` (`FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cid", isDirectory: true)`);
/// when `isTesting`: `NSTemporaryDirectory()/minimail-cid-<UUID>`.
static func cidCacheDirectory(testing: Bool) -> URL
```

---

## 4. Behaviour

### 4.1 `Sanitizer.sanitize(html:messageId:)` — architecture §9.1

Runs on the caller's executor (07: the `SyncEngine` actor, never inside `db.write`). Pure function of its inputs; no I/O; no logging.

```
sanitize(html, messageId):
 1. bytes = html.utf8.count; guard bytes <= maxInputBytes else throw .tooLarge(bytes: bytes)
 2. doc = try SwiftSoup.parseBodyFragment(html, "")
    doc.outputSettings().prettyPrint(pretty: false)
 3. Image pass (in document order):
    hasRemote = false; referenced = Set<String>()
    sawBackground = !(try doc.select("[background]")).isEmpty()
    for el in try doc.select("[background]"): try el.removeAttr("background")           // stage 1: drop, never neutralise
    for img in try doc.select("img"):
        src = (try img.attr("src")).trimmingCharacters(in: .whitespacesAndNewlines)
        lower = src.lowercased()
        if TrackingPixel.isTracking(img, src: src): try img.remove(); continue
        if lower.hasPrefix("cid:"):
            raw = String(src.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            raw = raw.removingPercentEncoding ?? raw                                     // RFC 2392: %xx decoded before matching [mime-rfc §5.4]
            cid = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if cid.isEmpty: try img.removeAttr("src")
            else:
                referenced.insert(cid)
                encoded = cid.addingPercentEncoding(withAllowedCharacters: cidPathAllowed) ?? cid
                try img.removeAttr("src"); try img.attr("src", "minimail-cid://\(messageId)/\(encoded)")
        elif lower.hasPrefix("data:image/"):
            /* keep verbatim */
        elif lower.hasPrefix("http://") || lower.hasPrefix("https://"):
            try img.removeAttr("data-src"); try img.removeAttr("src")                   // canonical order: data-src then src
            try img.attr("data-src", src); try img.attr("src", placeholderGIF); try img.addClass("mm-remote")
            hasRemote = true
        else:
            try img.removeAttr("src")                                                   // file:, ftp:, javascript:, protocol-relative "//", other data: MIMEs, unknown
        for a in ["srcset", "sizes", "loading"]: try img.removeAttr(a)
 4. strategy = DarkStrategyClassifier.classify(doc, sawBackgroundAttribute: sawBackground)
 5. fragment = try doc.body()?.html() ?? ""
    guard let cleaned = try SwiftSoup.clean(fragment, "", try whitelist(), outputSettings()) else throw .cleanFailed
 6. scrubbed = StyleScrubber.scrub(cleaned)
 7. return SanitizedBody(html: scrubbed.trimmingCharacters(in: .whitespacesAndNewlines), hasRemoteImages: hasRemote,
                         darkStrategy: strategy, referencedContentIDs: referenced)
```

`cidPathAllowed` = `CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%"))` so `/` and `%` inside a Content-ID are always encoded and the handler's `url.path` decodes to exactly one segment.

Edge cases:
- `html == ""` → `SanitizedBody(html: "", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: [])` (the caller may show the snippet; 07 does not special-case this).
- An `<img>` without `src` is left in place (no `src`, no placeholder).
- A remote image that is also a tracking pixel is removed before it can set `hasRemoteImages`.
- Two `<img>` with the same `cid:` → one entry in `referencedContentIDs`, both rewritten.
- The whitelist step (5) removes `<script>`, `<iframe>`, `<form>`, `<meta>`, `<link>`, `<base>`, `<object>`, `<embed>`, `<svg>`, `<video>`, `<audio>`, every `on*` attribute, `javascript:` hrefs (protocol test), `<a target>` values (enforced `_self`), `id` attributes, unknown inline CSS properties, CSS comments. Children text of removed elements is kept (Cleaner semantics `[html-rendering §1.1]`); `<script>`/`<style>` data nodes are dropped unless the parent is allowlisted (`style` is, `script` is not).
- Whether SwiftSoup keeps `src="minimail-cid://…"` under `addProtocols("img","src","data","minimail-cid")` + `preserveRelativeLinks(true)` is UNVERIFIED (`[html-rendering §1.1]` `testValidProtocol` note); `SanitizerTests.testCidRewriteSurvivesClean` proves it; fallback in §10 F2.
- Concurrency: `Whitelist`, `Document` are class instances created per call; nothing is shared; `Sanitizer` is safe to call from any actor.
- Performance: 500 KB newsletter < 150 ms in a release build on the macOS runner (`SanitizerTests.testNewsletter500KBUnder150ms`, §7).

### 4.2 `StyleScrubber.scrub`

`patterns` (ICU, compiled once with `NSRegularExpression(pattern:options: [.caseInsensitive])`, in this order):

| # | pattern | removes |
|---|---|---|
| 1 | `@import[^;]*;` | external CSS |
| 2 | `@font-face\s*\{[^}]*\}` | remote fonts |
| 3 | `url\s*\((?!\s*['"]?data:)[^)]*\)` | any non-`data:` `url()` (remote backgrounds, CSS trackers) |
| 4 | `expression\s*\(` | IE expressions |
| 5 | `behavior\s*:` | IE behaviors |
| 6 | `-moz-binding\s*:` | XBL |
| 7 | `javascript:` | leftover scheme text |
| 8 | `position\s*:\s*fixed` | keeps the mail inside its box |
| 9 | `position\s*:\s*absolute` | same |

Applied to the whole cleaned fragment (inline `style` attributes included). Replacement is `""`; the surrounding `;` or `}` stays (harmless CSS). Idempotent. `scrub("")` → `""`.

### 4.3 `TrackingPixel.isTracking(_:src:)`

```
guard lower(src) hasPrefix "http://" || "https://" else return false
alt = (try? img.attr("alt")) ?? ""; guard alt.trimmed.isEmpty else return false
style = ((try? img.attr("style")) ?? "").lowercased()
w = pixels(attr "width") ?? cssPixels(style, "width"); h = pixels(attr "height") ?? cssPixels(style, "height")
tiny = (w != nil && w! <= 2) || (h != nil && h! <= 2)
compact = style with all whitespace removed
hidden = compact.contains("display:none") || compact.contains("visibility:hidden") || opacityZero(compact)
return tiny || hidden
```
`opacityZero`: a declaration `opacity:<v>` where `Double(v) == 0` (so `opacity:0`, `opacity:0.0`, `opacity:.0` → true; `opacity:0.5` → false). `pixels`: trim, drop a trailing `px` (case-insensitive), `Int(...)`; `"0"` → 0 (tiny). Negative → treated as 0.

Matrix (fixture `tracking-pixels.html`, §5.9): (1) `width="1" height="1"` no alt → removed; (2) `style="width:1px;height:1px"` → removed; (3) `style="display:none"` 300×100 → removed; (4) `width="1" height="1" alt="logo"` → kept (alt present); (5) 200×50 no alt → kept; (6) `data:` 1×1 no alt → kept (not remote); (7) `cid:` 1×1 → kept; (8) `style="opacity:0.5" width="1"` → removed (tiny wins); (9) `width="50%"` no alt, no style → kept (percent → nil).

### 4.4 `DarkStrategyClassifier.classify`

```
html = (try? doc.body()?.html()) ?? ""; lower = html.lowercased()
if lower.contains("prefers-color-scheme") || lower.contains("color-scheme:") || lower.contains("supported-color-schemes"): return .native
hasBackground = regex(backgroundPattern, caseInsensitive).firstMatch(lower) != nil || lower.contains("bgcolor=") || sawBackgroundAttribute
imageHeavy = (try? doc.select("img").size()) ?? 0 >= 3
tableLayout = (try? doc.select("table").size()) ?? 0 >= 2
return (hasBackground || (imageHeavy && tableLayout)) ? .card : .plain
```
Called after the image pass, so removed tracking pixels are not counted and `background=` attributes (already dropped) are reported through `sawBackgroundAttribute`. `<style>` text is part of `body().html()` for a body fragment, so a stylesheet `background-color:` counts. The placeholder GIF URI and `data-src` values contain none of the tested tokens.

### 4.5 `SignatureSanitizer` and `QuoteExtractor`

`SignatureSanitizer.sanitize(html)`:
1. size guard as §4.1 step 1.
2. parse; `prettyPrint(false)`; remove every `[background]` attribute.
3. for each `img`: `src` trimmed; `http://`/`https://`/`data:image/` → kept verbatim; anything else (`cid:`, `javascript:`, `//host`, other `data:`) → `removeAttr("src")`; remove `srcset`, `sizes`, `loading`. No tracking-pixel test (the owner authored it).
4. `clean(fragment, "", signatureWhitelist(), outputSettings())` → nil → `.cleanFailed`.
5. `StyleScrubber.scrub` → trim → return.

`hasDataImages(html)`: parse as fragment; any `img` whose `src.lowercased().hasPrefix("data:")` → true; on parse error: `html.lowercased().contains("src=\"data:") || contains("src='data:")`.

`QuoteExtractor.quotable(sanitizedHTML)` — the inverse of the image neutralisation for outgoing quotes (architecture §7.2):
1. `doc = parseBodyFragment(html, "")`, `prettyPrint(false)`; on throw → return `sanitizedHTML`.
2. for `img` in `doc.select("img")`: if `img.hasAttr("data-src")`: `src = attr("data-src")`; `removeAttr("data-src")`; `removeClass("mm-remote")` (class list handled in step 3 anyway). Else if `attr("src").lowercased().hasPrefix("minimail-cid:")`: `img.remove()`.
3. for `el` in `doc.select("[class]")`: tokens = class split on whitespace; kept = tokens without prefix `mm-`; kept empty → `removeAttr("class")`; else `attr("class", kept.joined(separator: " "))`.
4. return `(try doc.body()?.html() ?? sanitizedHTML).trimmed`; any throw in steps 2–4 → `sanitizedHTML`.

Examples: `<div class="mm-plaintext"><div>hi</div></div>` → `<div><div>hi</div></div>`; `<img data-src="https://a/b.png" src="data:image/gif;base64,R0lG…" class="mm-remote x">` → `<img src="https://a/b.png" class="x">`; `<p>Logo <img src="minimail-cid://m1/ii_logo" alt="logo"></p>` → `<p>Logo </p>`.

### 4.6 `ThreadDocument.render` — architecture §9.2

Inputs: `subject`, `messages` (oldest first), `light`/`dark` tokens, `forcedScheme`, `imagesAllowed` (document). Output: the exact byte layout of §5.4 with `esc` = `OutgoingBodies.escape` applied to every interpolated header field (`subject`, `fromName`, `fromAddr`, `dateLabel`, `dateFull`, `snippet`, `toLine`, `ccLine`, `filename`, `sizeLabel`, `partId`, `id`). `bodyHTML` is inserted unescaped (it is the sanitized fragment).

```
render(...):
 1. head = "<!doctype html><html" + (forcedScheme == "dark" ? " data-theme=\"dark\"" : forcedScheme == "light" ? " data-theme=\"light\"" : "") + "><head>"
         + cspMeta(imagesAllowed) + META + "<style>" + css(light, dark) + "</style></head><body>"
    (forcedScheme values other than "light"/"dark" → no attribute)
 2. stripped = strippedIds(messages: messages)
 3. sections = messages.map { section($0, stripped: stripped.contains($0.id)) }.joined()
 4. return head + "<h1 class=\"mm-subject\">" + esc(subject.isEmpty ? "(No subject)" : subject) + "</h1>" + sections + "</body></html>"

section(m, stripped):
    classes = "mm-msg" + (m.isUnread ? " mm-unread" : "") + (m.expanded ? " mm-expanded" : " mm-collapsed")
              + " mm-" + (["plain","card","native"].contains(m.darkStrategy) ? m.darkStrategy : "plain") + (stripped ? " mm-stripped" : "")
    body = stripped ? SKELETON_TAP
         : m.bodyState == 2 ? SKELETON_RETRY
         : (m.bodyState == 0 || m.bodyHTML == nil) ? SKELETON_LOADING
         : cappedBody(m.imagesAllowed ? restoringRemoteImages(m.bodyHTML!) : m.bodyHTML!)
    images = (m.hasRemoteImages && !m.imagesAllowed && !stripped) ? IMAGES_ROW : ""
    att = m.attachments.isEmpty ? "" : "<div class=\"mm-att\">" + m.attachments.map(attRow).joined() + "</div>"
    return SECTION (§5.4) assembled from classes, esc(m.id), esc(m.fromAddr), esc(m.fromName.isEmpty ? m.fromAddr : m.fromName),
           esc(m.dateFull), esc(m.dateLabel), esc(m.snippet), esc(m.toLine), m.ccLine.map { "<br>Cc: " + esc($0) } ?? "", images, body, att

cappedBody(html):
    guard html.utf8.count > maxBodyBytes else return html
    cut = html.utf8 prefix of maxBodyBytes bytes, shortened to the last complete UTF-8 scalar (drop trailing continuation/lead bytes)
    return String(decoding: cut, as: UTF8.self) + "<p class=\"mm-skeleton\">Message truncated</p>"

restoringRemoteImages(html):
    regex = "data-src=\"([^\"]*)\" src=\"" + NSRegularExpression.escapedPattern(for: placeholderGIF) + "\""
    return regex.stringByReplacingMatches(in: html, with: "src=\"$1\"")     // relies on the canonical attribute order produced by §4.1 step 3

strippedIds(messages):
    sizes = messages.map { renderedBodyBytes: bodyState==1 && bodyHTML != nil ? min(bodyHTML.utf8.count, maxBodyBytes + 40) : 0 }
    total = sizes.reduce(+); stripped = []
    for (i, m) in messages.enumerated() where total > maxDocumentBytes:      // oldest first
        if !m.expanded && sizes[i] > 0 { stripped.insert(m.id); total -= sizes[i] }
    return stripped
```
Expanded messages are never stripped, so a thread whose expanded bodies alone exceed 6 MB still renders them (each capped at 1.5 MB).

`empty(light:dark:)` = `render(subject: "", messages: [], …)` minus the `<h1>`: exactly `head + "</body></html>"` with `imagesAllowed: false`, `forcedScheme: nil`.

`toggleScript(messageId:)` → §5.6 with `id` filtered to `[A-Za-z0-9_-]`. Returns a string that evaluates to `true` when the section exists, `false` otherwise (10 may inspect the result to decide a rebuild).

`csp(imagesAllowed:)` returns the exact strings of §5.4. `css(light:dark:)` returns the exact text of §5.5 with the eight tokens substituted (hex strings are inserted verbatim; the caller guarantees `^#[0-9a-f]{6}$` per 01's `SystemPalette`).

### 4.7 `WebBridge`

`userContentController(_:didReceive:)`: `guard message.name == handlerName, let msg = WebBridge.parse(message.body) else { Log.web.debug("web.bridge.ignored"); return }`; `onMessage(msg)`. Runs on the main actor (WebKit delivers script messages on the main thread; declare the conformance `@preconcurrency WKScriptMessageHandler` if the compiler rejects the isolated method — §10 A4).

`parse(_ body: Any)`:
```
guard let d = body as? [String: Any], let action = d["action"] as? String else return nil
let id = (d["id"] as? String) ?? ""; let part = (d["part"] as? String) ?? ""
switch action:
  "toggle": id.isEmpty ? nil : .toggle(messageId: id)
  "images": id.isEmpty ? nil : .loadImages(messageId: id)
  "retry":  id.isEmpty ? nil : .retry(messageId: id)
  "att":    (id.isEmpty || part.isEmpty) ? nil : .attachment(messageId: id, partId: part)
  default:  nil
```
`parse(actionURL:)`: scheme `minimail-action` (case-insensitive); `host` = action; path components after `/` (percent-decoded) = `[id]` or `[id, part]`; same table. `minimail-action://att/m1/2` → `.attachment("m1","2")`; `minimail-action://toggle/` → nil.

The click JS (§5.7) posts only for elements carrying `data-action` (itself or an ancestor up to `<html>`); it calls `preventDefault()` so the `href="#"` never navigates; ordinary `<a href="https://…">` clicks are untouched and reach `LinkPolicy`. The script does NOT toggle classes itself — 10 answers `.toggle` with `evaluateJavaScript(ThreadDocument.toggleScript(id))` (architecture §8.4), which keeps the app's `expanded` set the single source of truth.

### 4.8 `LinkPolicy`

`decision(for:type:)`:

| `type` | `url` | policy | open | action |
|---|---|---|---|---|
| `.linkActivated` | scheme ∈ {http, https, mailto, tel} (case-insensitive) | `.cancel` | url | nil |
| `.linkActivated` | scheme == `minimail-action` | `.cancel` | nil | `WebBridge.parse(actionURL:)` |
| `.linkActivated` | anything else (incl. nil, `about:blank#`, `javascript:`) | `.cancel` | nil | nil |
| `.other` | `about:blank` (absoluteString exactly, or `about:blank` with an empty fragment) | `.allow` | nil | nil |
| `.other` | anything else | `.cancel` | nil | nil |
| `.backForward`, `.reload`, `.formSubmitted`, `.formResubmitted`, unknown | any | `.cancel` | nil | nil |

`decidePolicyFor` (async form; only this variant is implemented — `[html-rendering §2.5]` "implement only one of the two"): `let d = Self.decision(for: navigationAction.request.url, type: navigationAction.navigationType)`; `if let u = d.open { openURL(u) }`; `if let a = d.action { onAction?(a) }`; `return d.policy`. `didFinish` → `onDidFinish?()`. `didFail*` → `Log.web.error("web.navigation.failed \(error.localizedDescription)")`. `createWebViewWith` → `if let u = navigationAction.request.url, ["http","https"].contains(u.scheme?.lowercased() ?? "") { openURL(u) }; return nil`.

### 4.9 `InlineImageStore.bytes(messageId:contentId:)` and `CIDSchemeHandler`

```
bytes(messageId, contentId):
 1. key = messageId + "/" + contentId
 2. if let hit = memory[key]: touch(key); return hit
 3. if let t = failedAt[key], clock().timeIntervalSince(t) < failureTTL: throw .recentlyFailed
    else failedAt[key] = nil
 4. if let task = inFlight[key]: return try await task.value                       // dedupe concurrent requests for the same key
 5. task = Task { try await fetchUncached(messageId, contentId, key) }; inFlight[key] = task
    defer inFlight[key] = nil
    do { return try await task.value }
    catch is CancellationError { throw }                                             // never cached as a failure
    catch { failedAt[key] = clock(); throw }

fetchUncached(messageId, contentId, key):
 a. file = cacheFileURL(root, messageId, contentId); mimeFile = file with extension "mime"
    if let data = try? Data(contentsOf: file), let mime = try? String(contentsOf: mimeFile, encoding: .utf8):
        remember(key, data, mime); return (data, mime)
 b. rows = try await db.read { try AttachmentRecord.filter(Column("messageId") == messageId).fetchAll($0) }
    record = rows.first { $0.contentId == contentId } ?? rows.first { $0.contentId?.lowercased() == contentId.lowercased() }
    guard var rec = record else throw .unknownContentId
 c. data = try await limiter.withPermit { try await download(rec, messageId) }         // limiter = RequestLimiter(max: maxInFlight), owned by the store
 d. write file (create <root>/<messageId>/ with intermediate dirs; `Data.write(options: .atomic)`), write mimeFile; errors → Log.web.error, continue
 e. mime = rec.mimeType.isEmpty ? "application/octet-stream" : rec.mimeType
    remember(key, data, mime); return (data, mime)

download(rec, messageId):
    if let id = rec.attachmentId:
        do { return try await gmail.getAttachment(messageId: messageId, attachmentId: id) }
        catch GmailError.notFound { /* fall through to one re-resolve */ }
    // re-resolve exactly once [gmail-api §6, gotcha 14]
    m = try await gmail.getMessage(id: messageId, format: .full, fields: "id,payload")   // 07 D14 mask
    parsed = MessageParser.parse(m)
    try await db.write { try BodyRepository.updateAttachmentIds($0, messageId: messageId, parsed: parsed.attachments) }
    guard let p = parsed.attachments.first(where: { $0.partId == rec.partId }) else throw .noBytes
    if let inline = p.inlineData { return inline }
    guard let id2 = p.attachmentId else throw .noBytes
    return try await gmail.getAttachment(messageId: messageId, attachmentId: id2)       // a 404 here propagates as GmailError.notFound

remember(key, data, mime): memory[key] = (data, mime); order.append(key); while memoryBytes > memoryBudgetBytes && order.count > 1: evict order.removeFirst()
purge(): memory = [:]; order = []; failedAt = [:]; try? FileManager.default.removeItem(at: root)     // inFlight tasks finish on their own; their writes recreate the directory (harmless)
```
`cacheFileURL(root:messageId:contentId:)` = `root/<messageId>/<hex(Insecure.SHA1(contentId utf8))>.bin`. `messageId` is used as a path component verbatim (Gmail ids are hex; a non-hex id is still safe because `/` cannot occur in a `url.host`).

Errors: `GmailError.offline`/`.network`/`.rateLimited`/`.server` are cached like any other failure for 60 s (a newsletter with 30 broken references costs one burst, not a storm — architecture §9.4); `.unauthorized` too (the reauth banner handles the account). Nothing here retries beyond `GmailClient`'s own retry table.

`CIDSchemeHandler`:
```
start(task):
    guard let url = task.request.url, let (mid, cid) = parse(url) else { task.didFailWithError(URLError(.badURL)); return }
    id = ObjectIdentifier(task); active.insert(id)
    tasks[id] = Task { [store] in
        let result: Result<(Data, String), Error>
        do { result = .success(try await store.bytes(messageId: mid, contentId: cid)) } catch { result = .failure(error) }
        guard active.contains(id) else { return }                           // stopped meanwhile: deliver nothing
        active.remove(id); tasks[id] = nil
        switch result:
        case .success((data, mime)):
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data); task.didFinish()
        case .failure(let e):
            Log.web.debug("web.cid.failed \(mid, privacy: .public) \(e)")
            task.didFailWithError(URLError(.resourceUnavailable))
    }
stop(task): id = ObjectIdentifier(task); active.remove(id); tasks[id]?.cancel(); tasks[id] = nil
parse(url): host = url.host (non-empty) ; path = url.path without leading "/" (non-empty) ; contentId = path.removingPercentEncoding (non-nil) → (host, contentId)
```
Both methods and the `Task` body run on the main actor (the class is `@MainActor`; the `Task` inherits it), so `active`/`tasks` need no lock. A `WKURLSchemeTask` is never touched after `stop`.

### 4.10 `WebViewHost`, `RuleLists`, `MailWebView`

`RuleLists.prepare()`:
```
guard blockAll == nil || imagesOnly == nil else return
guard let store = WKContentRuleListStore.default() else { Log.web.error("web.rulelist.nostore"); return }
blockAll = blockAll ?? (await load(store, blockAllIdentifier, blockAllJSON))
imagesOnly = imagesOnly ?? (await load(store, imagesOnlyIdentifier, imagesOnlyJSON))
load(store, id, json):
    if let existing = try? await store.contentRuleList(forIdentifier: id) { return existing }
    do { return try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) }     // nil → logged, returns nil
    catch { Log.web.error("web.rulelist.failed \(id, privacy: .public) \(error)"); return nil }
```
Bump the identifier suffix (`.v1` → `.v2`) whenever the JSON changes (the store keys by identifier `[html-rendering §2.2]`).

`makeConfiguration(cid:bridge:)` — architecture §9.3 verbatim, in this order:
1. `c.defaultWebpagePreferences.allowsContentJavaScript = false`
2. `c.defaultWebpagePreferences.preferredContentMode = .mobile`
3. `c.websiteDataStore = .nonPersistent()`
4. `c.dataDetectorTypes = []`
5. `c.suppressesIncrementalRendering = true`
6. `c.allowsInlineMediaPlayback = false`
7. `c.setURLSchemeHandler(cid, forURLScheme: CIDSchemeHandler.scheme)`
8. `if let l = RuleLists.blockAll { c.userContentController.add(l) }`
9. `c.userContentController.add(bridge, name: WebBridge.handlerName)`
10. `c.userContentController.addUserScript(WKUserScript(source: WebBridge.clickDelegateJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))`

Instance settings (applied once in the `webView` getter, before any load): `allowsLinkPreview = false`; `isOpaque = false`; `backgroundColor = UIColor.systemBackground`; `underPageBackgroundColor = UIColor.systemBackground`; `scrollView.contentInsetAdjustmentBehavior = .automatic`; `navigationDelegate = linkPolicy`; `uiDelegate = linkPolicy`; `#if DEBUG isInspectable = true #endif`. (`UIColor.systemBackground` is the stock theme's `background` token — 01 §3.6 — and adapts to `overrideUserInterfaceStyle`; `MailWebView` overwrites both colours with `backgroundColor` from the theme tokens on every update, so a future non-system theme is honoured.)

`prepare()`:
```
guard !isPrepared else return
await RuleLists.prepare()
let wv = webView                                                    // creates the instance if needed
if instanceCreatedBeforePrepare, let l = RuleLists.blockAll { wv.configuration.userContentController.add(l) }   // list was nil at creation
isPrepared = true
NotificationCenter observer on UIApplication.didReceiveMemoryWarningNotification (main queue) → if !isAttached { recycle() }
wv.loadHTMLString(ThreadDocument.empty(light: SystemPalette.cssTokens(for: .light), dark: SystemPalette.cssTokens(for: .dark)), baseURL: nil)
```
Called by `AppEnvironment.startDeferredWork` step c (+1 s after the first frame; skipped when `isTesting`). Opening a thread before `prepare()` finished works: the `webView` getter creates the instance immediately (CSP still forbids `https:` images; the block-all list is added when compilation finishes).

`setImagesAllowed(allowed)`:
```
guard allowed != imagesAllowed else return
let ucc = webView.configuration.userContentController
ucc.removeAllContentRuleLists()                                     // name UNVERIFIED [html-rendering §7] → fallback F3
if let l = allowed ? RuleLists.imagesOnly : RuleLists.blockAll { ucc.add(l) }
imagesAllowed = allowed
```
Rule lists apply to loads started after the swap; `MailWebView.updateUIView` always swaps before `load`.

`load(document:revision:)`: `cancelScheduledRecycle()`; `documentLoadState = Log.begin(.documentLoad)`; `linkPolicy.onDidFinish = { [weak self] in self?.endDocumentLoad() }`; `webView.loadHTMLString(document, baseURL: nil)`; `loadedRevision = revision`. `endDocumentLoad` ends the interval once (state set to nil).

`recycle()`: `cancelScheduledRecycle()`; `setImagesAllowed(false)`; `webView.loadHTMLString(ThreadDocument.empty(…), baseURL: nil)`; `loadedRevision = -1`; `Log.web.debug("web.recycle")`. Only touches an already-created instance (`guard webViewIfCreated != nil else return`).

`didLeaveThread()`: `cancelScheduledRecycle()`; `recycleTask = Task { try? await Task.sleep(for: .seconds(Self.recycleDelay)); guard !Task.isCancelled, !isAttached else return; recycle() }`. `didAttach()`: `isAttached = true; cancelScheduledRecycle()`. `didDetach()`: `isAttached = false`. Architecture §8.4 says the screen calls `recycle()` on leave and §9.3 says "60 s after leaving": 10 should call `didLeaveThread()` (keeps a back-and-forth between inbox and thread free of a warm-up) — see §10 A6.

`makeThrowawayWebView()`: configuration with steps 1–6 and 8 of `makeConfiguration` (no scheme handler, no message handler, no user script); `WKWebView(frame: .zero, configuration:)` with the same instance settings, `navigationDelegate = uiDelegate = throwawayPolicy` (`LinkPolicy` with `openURL = { _ in }`, held by the host). The caller (13) owns the returned view and releases it when the editor disappears.

`MailWebView`:
```
makeUIView: container = MailWebContainerView(); container.host(host.webView); host.didAttach(); return container
updateUIView(container, context):
    container.host(host.webView)                                    // re-parent if a previous container still holds it
    let wv = host.webView
    if context.coordinator.appliedStyle != interfaceStyle { wv.overrideUserInterfaceStyle = interfaceStyle; context.coordinator.appliedStyle = interfaceStyle }
    wv.backgroundColor = backgroundColor; wv.underPageBackgroundColor = backgroundColor
    guard context.coordinator.appliedRevision != revision else return
    host.setImagesAllowed(imagesAllowed)
    host.load(document: document, revision: revision)
    context.coordinator.appliedRevision = revision
dismantleUIView: host.didDetach()
```
Theme changes reach the web view two ways: `overrideUserInterfaceStyle` (primary) and the `data-theme` attribute already inside `document` (10 passes `theme.forcedDocumentTheme` to `render`) — both written from day one (architecture §9.5). A theme change must bump `revision` (10) because the document text changes.

### 4.11 `AppEnvironment` insertion (`[08]`)

In `init(testing:)` at the `// [05][07][08]` point, after 07's block:
```swift
inlineImages = InlineImageStore(gmail: gmail, db: db, cacheDirectory: AppEnvironment.cidCacheDirectory(testing: testing))
webBridge = WebBridge()
webHost = WebViewHost(cid: CIDSchemeHandler(store: inlineImages), bridge: webBridge)
```
Construction only: `WebViewHost.init` stores its dependencies and does NOT create the `WKWebView` (architecture §12.2 forbids `WKWebView` in launch step 1). `startDeferredWork` step c replaces the `// [08]` comment with `await webHost.prepare()` (not reached when `isTesting`). Wipe tail (`auth.hooks.wipeAccountData`, after 07's tail): `await inlineImages.purge(); webHost.recycle()`.

### 4.12 Isolation summary

| Type | Isolation | Notes |
|---|---|---|
| `Sanitizer`, `StyleScrubber`, `TrackingPixel`, `DarkStrategyClassifier`, `SignatureSanitizer`, `QuoteExtractor`, `ThreadDocument` | nonisolated (package) | pure; callable from any actor; no shared mutable state (regexes are `static let`, `NSRegularExpression` is thread-safe) |
| `InlineImageStore` | `actor` | owns memory/disk/failure caches and its own `RequestLimiter(max: 2)` |
| `WebViewHost`, `RuleLists`, `MailWebView`, `WebBridge`, `CIDSchemeHandler`, `LinkPolicy` | `@MainActor` (project default) | WebKit calls all delegate/handler methods on the main thread; conformances may need `@preconcurrency` (§10 A4) |

---

## 5. Data

### 5.1 Sanitizer whitelist (`Sanitizer.whitelist()`), `[html-rendering §1.3]`

```swift
let w = try Whitelist.relaxed()
    .addTags("center", "font", "hr", "s", "del", "ins", "abbr", "address", "style", "wbr")
    .addAttributes(":all", "style", "class", "dir", "lang", "align", "valign", "width", "height", "bgcolor", "border", "cellpadding", "cellspacing")
    .addAttributes("img", "data-src")
    .addAttributes("font", "face", "size", "color")
    .addAttributes("a", "href", "title")
    .addAttributes("blockquote", "type")
    .addProtocols("a", "href", "http", "https", "mailto", "tel")
    .addProtocols("img", "src", "data", "minimail-cid")
    .addCSSProperties(":all", Sanitizer.allowedCSSProperties)     // spread as variadic
    .preserveRelativeLinks(true)
try w.addEnforcedAttribute("a", "target", "_self")
```
`Whitelist.relaxed()` already allows: `a b blockquote br caption cite code col colgroup dd div dl dt em h1 h2 h3 h4 h5 h6 i img li ol p pre q small span strike strong sub sup table tbody td tfoot th thead tr u ul` with `a[href,title] blockquote[cite] col[span,width] colgroup[span,width] img[align,alt,height,src,title,width] ol[start,type] q[cite] table[summary,width] td[abbr,axis,colspan,rowspan,width] th[abbr,axis,colspan,rowspan,scope,width] ul[type]` and protocols `a[href]: ftp http https mailto`, `img[src]: http https`, `blockquote/cite/q[cite]: http https` (jsoup semantics; SwiftSoup's port is assumed identical — §10 A1). `ftp` on `a[href]` is removed with `.removeProtocols("a", "href", "ftp")`; `img[src]` `http`/`https` are removed with `.removeProtocols("img", "src", "http", "https")` so a remote `src` that escaped the image pass cannot survive.

`Sanitizer.allowedCSSProperties` (exact, in this order):
```
color, background, background-color, font, font-family, font-size, font-weight, font-style,
text-decoration, text-align, line-height, letter-spacing, vertical-align, white-space,
margin, margin-top, margin-right, margin-bottom, margin-left,
padding, padding-top, padding-right, padding-bottom, padding-left,
border, border-top, border-right, border-bottom, border-left, border-collapse, border-spacing, border-radius, border-color, border-width, border-style,
width, min-width, max-width, height, max-height, display, float, clear, overflow, word-break, word-wrap, overflow-wrap, table-layout,
list-style, list-style-type, text-transform, text-indent, direction, unicode-bidi, mso-hide
```
Deliberately absent: `position`, `behavior`, `-moz-binding`, `expression`, `filter`, `content`, `pointer-events`, `z-index`, `background-image`, `cursor`, `visibility`, `opacity`.

### 5.2 `StyleScrubber.patterns` (Swift raw strings)

```swift
static let patterns: [String] = [
    #"@import[^;]*;"#,
    #"@font-face\s*\{[^}]*\}"#,
    #"url\s*\((?!\s*['"]?data:)[^)]*\)"#,
    #"expression\s*\("#,
    #"behavior\s*:"#,
    #"-moz-binding\s*:"#,
    #"javascript:"#,
    #"position\s*:\s*fixed"#,
    #"position\s*:\s*absolute"#,
]
```

### 5.3 Content rule lists (byte-exact JSON; `[html-rendering §2.2]`)

`RuleLists.blockAllJSON`:
```json
[
  { "trigger": { "url-filter": "^https?://" }, "action": { "type": "block" } },
  { "trigger": { "url-filter": "^wss?://" },   "action": { "type": "block" } },
  { "trigger": { "url-filter": "^ftp://" },    "action": { "type": "block" } },
  { "trigger": { "url-filter": "^file://" },   "action": { "type": "block" } }
]
```
`RuleLists.imagesOnlyJSON`:
```json
[
  { "trigger": { "url-filter": "^https?://" }, "action": { "type": "block" } },
  { "trigger": { "url-filter": "^https://", "resource-type": ["image"] }, "action": { "type": "ignore-previous-rules" } },
  { "trigger": { "url-filter": "^wss?://" },   "action": { "type": "block" } },
  { "trigger": { "url-filter": "^ftp://" },    "action": { "type": "block" } },
  { "trigger": { "url-filter": "^file://" },   "action": { "type": "block" } }
]
```
Plain `http://` images stay blocked after opt-in (no mixed content). `data:` and `minimail-cid:` never match `^https?://`.

### 5.4 Thread document template (exact; `{…}` = substitution, `esc` applied as §4.6)

```html
<!doctype html><html{ data-theme="dark" | data-theme="light" | }><head>
<meta http-equiv="Content-Security-Policy" content="{csp}">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<style>{css}</style></head><body>
<h1 class="mm-subject">{subject}</h1>
<section class="mm-msg{ mm-unread}{ mm-collapsed| mm-expanded} mm-{plain|card|native}{ mm-stripped}" data-id="{id}">
<div class="mm-hdr" data-action="toggle"><span class="mm-from" title="{fromAddr}">{fromName}</span><span class="mm-date" title="{dateFull}">{dateLabel}</span></div>
<div class="mm-snippet">{snippet}</div>
<div class="mm-to">To: {toLine}{<br>Cc: {ccLine}}</div>
{<div class="mm-images"><a data-action="images" href="#">Load images</a></div>}
<div class="mm-body">{body}</div>
{<div class="mm-att">{<a data-action="att" data-part="{partId}" href="#">{PAPERCLIP} {filename} · {sizeLabel}</a>}…</div>}
</section>
…
</body></html>
```
Line breaks in the listing above are literal `\n` in the output between the head lines and between sections' elements (tests use `contains` on single lines, never on multi-line spans).

Constants:
- `csp` images off: `default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`
- `csp` images on: `default-src 'none'; img-src data: minimail-cid: https:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`
- `SKELETON_LOADING` = `<span class="mm-skeleton">Loading…</span>` (U+2026)
- `SKELETON_RETRY` = `<span class="mm-skeleton">Couldn't load this message · <a data-action="retry" href="#">Retry</a></span>` (U+00B7 middle dot)
- `SKELETON_TAP` = `<span class="mm-skeleton">Tap to load this message</span>`
- `IMAGES_ROW` = `<div class="mm-images"><a data-action="images" href="#">Load images</a></div>`
- `PAPERCLIP` = `<svg class="mm-clip" width="12" height="12" viewBox="0 0 24 24" aria-hidden="true"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`
- `placeholderGIF` = `data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7`
- Attachment separator: ` · ` (space, U+00B7, space).

### 5.5 `ThreadDocument.css(light:dark:)` (exact text; `L.x`/`D.x` = token hex)

```css
:root{color-scheme:light dark;--mm-bg:L.background;--mm-surface:L.surface;--mm-text:L.text;--mm-secondary:L.secondaryText;--mm-accent:L.accent;--mm-sep:L.separator;--mm-link:L.link;--mm-card:L.cardBackground}
@media (prefers-color-scheme:dark){:root{--mm-bg:D.background;--mm-surface:D.surface;--mm-text:D.text;--mm-secondary:D.secondaryText;--mm-accent:D.accent;--mm-sep:D.separator;--mm-link:D.link;--mm-card:D.cardBackground}}
html[data-theme=dark]{--mm-bg:D.background;--mm-surface:D.surface;--mm-text:D.text;--mm-secondary:D.secondaryText;--mm-accent:D.accent;--mm-sep:D.separator;--mm-link:D.link;--mm-card:D.cardBackground}
html[data-theme=light]{--mm-bg:L.background;--mm-surface:L.surface;--mm-text:L.text;--mm-secondary:L.secondaryText;--mm-accent:L.accent;--mm-sep:L.separator;--mm-link:L.link;--mm-card:L.cardBackground}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:transparent;color:var(--mm-text);font:-apple-system-body;font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;overflow-wrap:break-word;-webkit-touch-callout:none}
h1.mm-subject{font:600 22px/1.2 -apple-system;margin:12px 16px 4px}
.mm-msg{border-top:1px solid var(--mm-sep)}
.mm-hdr{padding:10px 16px;display:flex;gap:8px;align-items:baseline}
.mm-from{font-weight:600;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mm-msg.mm-unread .mm-from::before{content:"";display:inline-block;width:8px;height:8px;border-radius:4px;background:var(--mm-accent);margin-right:6px}
.mm-date{color:var(--mm-secondary);font-size:13px;white-space:nowrap}
.mm-to{color:var(--mm-secondary);font-size:13px;padding:0 16px 8px}
.mm-body{padding:8px 16px 16px}
.mm-collapsed .mm-body,.mm-collapsed .mm-to,.mm-collapsed .mm-att,.mm-collapsed .mm-images{display:none}
.mm-snippet{display:none}
.mm-collapsed .mm-snippet{display:block;color:var(--mm-secondary);padding:0 16px 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mm-att{display:flex;gap:8px;padding:0 16px 12px;flex-wrap:wrap}
.mm-att a{border:1px solid var(--mm-sep);border-radius:8px;padding:6px 10px;color:var(--mm-accent);text-decoration:none;font-size:13px}
.mm-clip{vertical-align:-1px}
.mm-images{margin:0 16px 8px;font-size:13px}
.mm-images a{color:var(--mm-accent)}
.mm-skeleton{color:var(--mm-secondary);font-style:italic}
.mm-body a{color:var(--mm-link)}
img{max-width:100% !important;height:auto}
table{max-width:100% !important}
pre{white-space:pre-wrap}
blockquote[type=cite]{margin:0 0 0 .8ex;border-left:2px solid var(--mm-sep);padding-left:1ex}
.mm-remote{min-width:1px;min-height:1px}
.mm-plaintext{white-space:pre-wrap}
@media (prefers-color-scheme:dark){html:not([data-theme=light]) .mm-plain .mm-body{color:#E5E5EA}html:not([data-theme=light]) .mm-plain .mm-body a{color:var(--mm-link)}html:not([data-theme=light]) .mm-plain .mm-body [style*="color"]{color:inherit !important}html:not([data-theme=light]) .mm-plain .mm-body font[color]{color:inherit !important}html:not([data-theme=light]) .mm-plain .mm-body blockquote[type=cite]{border-left-color:var(--mm-sep)}html:not([data-theme=light]) .mm-card .mm-body{background:var(--mm-card);color:#000;color-scheme:light;border-radius:12px;margin:0 12px 12px;padding:12px;overflow:hidden}}
html[data-theme=dark] .mm-plain .mm-body{color:#E5E5EA}html[data-theme=dark] .mm-plain .mm-body a{color:var(--mm-link)}html[data-theme=dark] .mm-plain .mm-body [style*="color"]{color:inherit !important}html[data-theme=dark] .mm-plain .mm-body font[color]{color:inherit !important}html[data-theme=dark] .mm-plain .mm-body blockquote[type=cite]{border-left-color:var(--mm-sep)}html[data-theme=dark] .mm-card .mm-body{background:var(--mm-card);color:#000;color-scheme:light;border-radius:12px;margin:0 12px 12px;padding:12px;overflow:hidden}
```
Each line above is one line of the emitted CSS (joined with `\n`). The `html:not([data-theme=light])` guard is this spec's implementation of "fallback for forced themes": a forced Light theme on a dark system never gets dark overrides even if `overrideUserInterfaceStyle` does not propagate (§14 #5). `mm-native` sections get no override — the sender's own dark CSS runs.

### 5.6 `toggleScript(messageId:)`

```js
(function(){var s=document.querySelector('section.mm-msg[data-id="{id}"]');if(!s){return false;}s.classList.toggle('mm-collapsed');s.classList.toggle('mm-expanded');return true;})();
```

### 5.7 `WebBridge.clickDelegateJS`

```js
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
```

### 5.8 Inline-image cache layout

```
<Caches>/cid/<messageId>/<sha1hex(contentId)>.bin     bytes (as returned by attachments.get, base64url-decoded by GmailClient)
<Caches>/cid/<messageId>/<sha1hex(contentId)>.mime    UTF-8 text, e.g. "image/png"
```
`Maintenance.purgeFiles` (07) removes files older than 7 days under `<Caches>/cid`; `InlineImageStore.purge()` removes the directory on sign-out. Memory cache: at most `memoryBudgetBytes` (8,000,000) of `Data` in insertion order (oldest evicted). Failure cache: `[key: Date]`, TTL 60 s.

### 5.9 Fixture outlines (`Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/`)

| File | Content outline (the implementing agent writes the exact bytes; each numbered item must be present) |
|---|---|
| `newsletter.html` | `<!--[if mso]>…<![endif]-->` comment; `<style>` with `@import url(https://fonts.example/x.css);`, `@font-face{font-family:X;src:url(https://f.example/x.woff)}`, `.hero{background:url(https://img.example/bg.png)}`, `.dark{background-color:#000}`; `<table bgcolor="#f4f4f4" width="600">` wrapping 2 nested tables; 4 remote `<img src="https://img.example/{1,2,3,4}.png" width="600" height="200" alt="…">`; one tracking pixel `<img src="https://t.example/o.gif" width="1" height="1">`; `<script>alert(1)</script>`; `<a href="https://shop.example/x" target="_blank">Buy</a>`; ≈ 6–8 KB |
| `plain-mail.html` | `<div dir="ltr">Hi Alice,<br><br>see <a href="https://newtelco.de/x">the site</a>.<br><span style="color:#444444">grey note</span><br><div>Regards</div></div>` |
| `dark-native.html` | `<style>:root{color-scheme:light dark}@media (prefers-color-scheme:dark){body{background:#111;color:#eee}}</style><table bgcolor="#ffffff"><tr><td>Native dark mail</td></tr></table>` |
| `tracking-pixels.html` | the nine `<img>` variants of §4.3 in that order, each on its own line, ids `p1`…`p9` in `title` attributes |
| `malformed.html` | `<!--[if mso]><table><tr><td><![endif]--><div><table><tr><td>unclosed cell<b><i>mis</b>nested</i><p>stray < less than & amp<div>` |
| `inline-cid.html` | `<img src="cid:ii_logo@newtelco.de" alt="logo">`, `<img src="CID:<ii_2>">`, `<img src="cid:a%40b">`, `<img src="https://r.example/x.png" width="100" height="40" alt="r">`, `<img src="data:image/png;base64,iVBORw0KGgo=" alt="d">` |
| `signature.html` | `<div dir="ltr"><b>Jane Doe</b><br>newtelco GmbH<br><img src="https://cdn.newtelco.de/logo.png" width="120" height="30" alt="newtelco"><img src="data:image/png;base64,iVBORw0KGgo=" alt="d"><script>alert(1)</script><a href="javascript:alert(2)">x</a><a href="https://newtelco.de" style="color:#0b5394">newtelco.de</a></div>` |
| `xss-samples.html` | numbered lines `<!-- 1 -->…`: (1) `<img src="x" onerror="alert(1)">`; (2) `<a href="javascript:alert(1)">j</a>`; (3) `<a href="  JaVaScRiPt:alert(1)">j2</a>`; (4) `<svg><script>alert(1)</script></svg>`; (5) `<iframe src="https://evil.example"></iframe>`; (6) `<form action="https://evil.example"><input name="a"><button>go</button></form>`; (7) `<meta http-equiv="refresh" content="0;url=https://evil.example">`; (8) `<object data="https://evil.example/x.swf"></object>`; (9) `<style>@import url(https://evil.example/x.css);</style>`; (10) `<div style="width:expression(alert(1))">e</div>`; (11) `<a href="https://ok.example" target="_blank">t</a>`; (12) `<img srcset="https://evil.example/x.png 1x" src="https://ok.example/y.png" alt="s">`; (13) `<base href="https://evil.example/">`; (14) `<link rel="stylesheet" href="https://evil.example/x.css">`; (15) `<div style="position:fixed;top:0">f</div>`; (16) `<img src="//evil.example/p.png" alt="pr">`; (17) `<td background="https://evil.example/bg.png">bg</td>`; (18) `<a href="https://ok.example" onclick="alert(1)">c</a>` |

---

## 6. UI

This module owns no screen. The visible document (§5.4/§5.5) is rendered by `ThreadScreen` (module 10); its conventions — subject `h1`, header rows with unread dot, snippet when collapsed, "Load images" row, attachment chips with paperclip, skeleton texts — are fixed by the template above and by architecture §8.4. Accessibility: the document uses `font:-apple-system-body` so Dynamic Type applies to header text; 10 reloads on `UIContentSizeCategory.didChangeNotification`. Haptics, navigation and toolbar are module 10's.

---

## 7. Tests

Package tests: `cd Packages/MailCore && swift test` (Linux when SwiftSoup builds — architecture §14 #1 — and always on macOS; `MAILCORE_SKIP_HTML=1` omits `MailHTMLTests`). App tests: `make test-one T=minimailTests/<Class>` on the macOS runner. `HTMLFixtures.load("newsletter")` reads `Bundle.module.url(forResource: "newsletter", withExtension: "html", subdirectory: "Fixtures/html")`. `sanitize(_ name)` = `try Sanitizer.sanitize(html: HTMLFixtures.load(name), messageId: "m1")`.

### 7.1 `MailHTMLTests` (swift test)

| Test file | Test | Setup | Assertions |
|---|---|---|---|
| `SanitizerTests.swift` | `testScriptIframeFormMetaRemoved` | `sanitize("xss-samples")` | html contains none of `<script`, `<iframe`, `<form`, `<input`, `<button`, `<meta`, `<object`, `<base`, `<link`, `<svg`; contains `>e<` (text of (10) kept) and `>go<` (button text kept, Cleaner semantics) |
| | `testEventHandlersAndJavascriptURLsRemoved` | same | html contains no `onerror`, `onclick`, `javascript:` (case-insensitive); (2)/(3) become `<a>j</a>` / `<a>j2</a>` without `href` (or with `href` removed — assert `href="javascript` absent) |
| | `testTargetEnforcedSelf` | same | every `<a ` with `href="https://ok.example"` carries `target="_self"`; no `target="_blank"` |
| | `testSrcsetAndProtocolRelativeDropped` | same | (12): `srcset` absent, `data-src="https://ok.example/y.png"` present; (16): the `<img alt="pr">` has no `src` and no `data-src`; (17): `background=` absent |
| | `testRemoteImageNeutralised` | `sanitize("plain-mail")` + inline `<img src="https://a/b.png" alt="x" width="10" height="10">` | html contains `data-src="https://a/b.png" src="` + placeholder + `"` (adjacent, that order) and `class="mm-remote"`; `hasRemoteImages == true` |
| | `testDataImageKept` | `sanitize("inline-cid")` | html contains `src="data:image/png;base64,iVBORw0KGgo="` |
| | `testCidRewriteAndReferencedSet` | `sanitize("inline-cid")` | html contains `src="minimail-cid://m1/ii_logo%40newtelco.de"`, `src="minimail-cid://m1/ii_2"`, `src="minimail-cid://m1/a%40b"`; `referencedContentIDs == ["ii_logo@newtelco.de", "ii_2", "a@b"]` |
| | `testCidRewriteSurvivesClean` | `Sanitizer.sanitize(html: "<img src=\"cid:x\">", messageId: "m9")` | html == `<img src="minimail-cid://m9/x">` (exact; proves the whitelist protocol test keeps the custom scheme) |
| | `testTrackingPixelRemovedBeforeRemoteFlag` | `Sanitizer.sanitize(html: "<p>a</p><img src=\"https://t/o.gif\" width=\"1\" height=\"1\">", messageId: "m1")` | html contains no `<img`; `hasRemoteImages == false` |
| | `testStyleBlockScrubbed` | `sanitize("newsletter")` | html contains `<style>`; contains none of `@import`, `@font-face`, `url(https://img.example/bg.png)`; contains `.dark{background-color:#000}` |
| | `testNewsletterIsCard` | same | `darkStrategy == .card`; `hasRemoteImages == true`; html contains no `<script` |
| | `testPlainMailIsPlain` | `sanitize("plain-mail")` | `darkStrategy == .plain`; html contains `style="color:#444444"` (allowed property kept) and `href="https://newtelco.de/x"` |
| | `testDarkNativeIsNative` | `sanitize("dark-native")` | `darkStrategy == .native`; html contains `prefers-color-scheme` |
| | `testMalformedDoesNotThrow` | `sanitize("malformed")` | no throw; html contains `unclosed cell` and `mis`; contains no `<!--` |
| | `testTooLargeThrows` | `String(repeating: "a", count: Sanitizer.maxInputBytes + 1)` | throws `SanitizerError.tooLarge(bytes: maxInputBytes + 1)` |
| | `testExactlyMaxBytesAccepted` | `"<p>" + "a"×(maxInputBytes − 7) + "</p>"` | no throw |
| | `testEmptyInput` | `sanitize(html: "", messageId: "m1")` | `SanitizedBody(html: "", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: [])` |
| | `testUnknownCSSPropertyDropped` | `<div style="color:red;position:absolute;z-index:9">x</div>` | html contains `color:red`; contains neither `position` nor `z-index` |
| | `testIdAttributeDropped` | `<div id="a" class="b" dir="rtl">x</div>` | html contains `class="b"` and `dir="rtl"`, no `id=` |
| | `testFromPlainText` | `Sanitizer.fromPlainText("a < b\n\nc")` | `.html == PlainTextHTML.convert("a < b\n\nc")`; `.darkStrategy == .plain`; `.hasRemoteImages == false`; `referencedContentIDs.isEmpty` |
| | `testPlaceholderMatchesThreadDocument` | — | `Sanitizer.placeholderGIF == ThreadDocument.placeholderGIF` |
| | `testNewsletter500KBUnder150ms` | `XCTSkipUnless(ProcessInfo.processInfo.environment["MAILCORE_PERF"] == "1")`; html = newsletter.html body repeated until ≥ 500,000 bytes | `measure {}` block; assert wall time of one run < 0.150 s (`Date()` around a single call after one warm-up call) |
| `StyleScrubberTests.swift` | `testEachPattern` | table of 9 inputs, one per pattern (e.g. `"a{@import url(x);b}"` → `"a{b}"`, `"x:url( 'https://a' )"` → `"x:"`, `"POSITION : FIXED"` → `""`) | exact outputs |
| | `testDataURLKept` | `"background:url(data:image/png;base64,AAAA)"` and `"url( \"data:image/gif;base64,R0\" )"` | unchanged |
| | `testIdempotent` | scrub twice | equal |
| `TrackingPixelTests.swift` | `testMatrix` | parse `tracking-pixels.html`, select `img` in order | `isTracking` == `[true, true, true, false, false, false, false, true, false]` |
| | `testPixelParsers` | — | `pixels("12px") == 12`, `pixels(" 3 ") == 3`, `pixels("50%") == nil`, `pixels("auto") == nil`, `pixels("") == nil`; `cssPixels(style: "min-width:1px;width:200px", property: "width") == 200`; `cssPixels(style: "WIDTH : 1PX", property: "width") == 1` |
| `DarkStrategyClassifierTests.swift` | `testMatrix` | table: `<p>hi</p>` → plain; `<div style="background-color:#fff">` → card; `<div style="background:transparent">` → plain; `<td bgcolor="#eee">` → card; 3 imgs + 2 tables no bg → card; 3 imgs + 1 table → plain; `<style>@media (prefers-color-scheme:dark){}</style>` → native; `<meta name="supported-color-schemes">` text inside `<style>` → native; `sawBackgroundAttribute: true` with `<p>` → card | as listed |
| `SignatureSanitizerTests.swift` | `testKeepsHttpsImageDropsScript` | `SignatureSanitizer.sanitize(HTMLFixtures.load("signature"))` | contains `src="https://cdn.newtelco.de/logo.png"`, `src="data:image/png;base64,iVBORw0KGgo="`, `style="color:#0b5394"`; contains no `<script`, no `javascript:`, no `data-src`, no placeholder GIF |
| | `testCidLosesSrc` | `<img src="cid:x" alt="a">` | result == `<img alt="a">` |
| | `testTooLarge` | 2 MiB + 1 | throws `.tooLarge` |
| | `testHasDataImages` | fixture → true; `<p>x</p>` → false; `"<img src='DATA:image/png;base64,AA'>"` → true; `"<img src=\"data:"` (malformed) → true |
| `QuoteExtractorTests.swift` | `testRestoresDataSrc` | `<p><img data-src="https://a/b.png" src="` + placeholder + `" class="mm-remote x" alt="i"></p>` | result == `<p><img src="https://a/b.png" class="x" alt="i"></p>` |
| | `testRemovesCidImages` | `<p>Logo <img src="minimail-cid://m1/ii_logo" alt="logo"> end</p>` | result == `<p>Logo  end</p>` |
| | `testRemovesMMClasses` | `<div class="mm-plaintext"><div class="mm-a keep">x</div></div>` | result == `<div><div class="keep">x</div></div>` |
| | `testRoundTripFromSanitizer` | `QuoteExtractor.quotable(sanitize("plain-mail").html)` | contains `href="https://newtelco.de/x"`; contains no `mm-` |
| | `testNeverThrows` | `quotable("<<<>>>\u{0}")` | returns a String (no crash) |

### 7.2 `MailCoreTests/ThreadDocumentTests.swift` (swift test)

Helpers: `L = ThemeCSSTokens(background:"#ffffff", surface:"#f2f2f7", text:"#000000", secondaryText:"#3c3c43", accent:"#007aff", separator:"#c6c6c8", link:"#007aff", cardBackground:"#ffffff")`, `D = …(background:"#000000", text:"#ffffff", accent:"#0a84ff", …, cardBackground:"#ffffff")`; `msg(id:, expanded:, body:, state:, remote:, allowed:)` builder with defaults (fromName "Alice", fromAddr "alice@example.com", toLine "Bob <bob@example.com>", dateLabel "14:32", dateFull "11 Sep 2026 14:32", snippet "hi", isUnread false, darkStrategy "plain", attachments []).

| Test | Setup | Assertions |
|---|---|---|
| `testCSPImagesOff` | `render(subject:"S", messages:[msg("a")], L, D, forcedScheme:nil, imagesAllowed:false)` | contains `content="default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"`; `csp(imagesAllowed:false)` equals the same value |
| `testCSPImagesOn` | `imagesAllowed:true` | contains `img-src data: minimail-cid: https:;` |
| `testForcedSchemeAttribute` | `forcedScheme:"dark"` / `"light"` / `nil` / `"blue"` | starts with `<!doctype html><html data-theme="dark"><head>` / `…data-theme="light"…` / `<!doctype html><html><head>` / `<!doctype html><html><head>` |
| `testCSSVariablesFromTokens` | any | contains `:root{color-scheme:light dark;--mm-bg:#ffffff;` and `@media (prefers-color-scheme:dark){:root{--mm-bg:#000000;` and `html[data-theme=dark]{--mm-bg:#000000;` and `html[data-theme=light]{--mm-bg:#ffffff;` |
| `testSectionClasses` | messages: `a` (unread, expanded, "card"), `b` (read, collapsed, "native"), `c` (collapsed, darkStrategy "weird") | contains `<section class="mm-msg mm-unread mm-expanded mm-card" data-id="a">`, `<section class="mm-msg mm-collapsed mm-native" data-id="b">`, `<section class="mm-msg mm-collapsed mm-plain" data-id="c">` |
| `testHeaderFieldsEscaped` | subject `<b>&"x"`, fromName `A<B`, toLine `"Bob" <bob@x>`, snippet `1<2` | contains `<h1 class="mm-subject">&lt;b&gt;&amp;&quot;x&quot;</h1>`, `>A&lt;B</span>`, `To: &quot;Bob&quot; &lt;bob@x&gt;`, `<div class="mm-snippet">1&lt;2</div>` |
| `testEmptySubjectPlaceholder` | subject `""` | contains `<h1 class="mm-subject">(No subject)</h1>` |
| `testCcLine` | ccLine `"c@x"` / nil | contains `<br>Cc: c@x</div>` / does not contain `Cc:` |
| `testBodyStates` | `a` state 0, `b` state 1 body `<p>B</p>`, `c` state 2, `d` state 1 body nil | `a`: `<div class="mm-body"><span class="mm-skeleton">Loading…</span></div>`; `b`: `<div class="mm-body"><p>B</p></div>`; `c`: contains `Couldn't load this message · <a data-action="retry" href="#">Retry</a>`; `d`: same as `a` |
| `testDataSrcRestoredOnlyForAllowedMessage` | `a` and `b` both body `<img data-src="https://x/1.png" src="PLACEHOLDER" class="mm-remote">`, remote true; `a.imagesAllowed=true`, `b` false; document `imagesAllowed:true` | section `a` contains `<img src="https://x/1.png" class="mm-remote">`; section `b` still contains `data-src="https://x/1.png" src="PLACEHOLDER"` and the Load-images row; section `a` has no Load-images row |
| `testLoadImagesRowOnlyWhenRemoteAndNotAllowed` | remote false / remote true+allowed / remote true+not allowed | row absent / absent / present (`IMAGES_ROW` exact) |
| `testAttachmentsRow` | attachments `[("1","a.pdf","12 KB"), ("2","b<c.png","3 KB")]` | contains `<a data-action="att" data-part="1" href="#">` + PAPERCLIP + ` a.pdf · 12 KB</a>` and `data-part="2" href="#">…b&lt;c.png · 3 KB</a>`; no attachments → no `mm-att` |
| `testPerBodyCap` | body = `"<p>" + "é"×800_000 + "</p>"` (≈ 1.6 MB) | rendered body byte count ≤ `maxBodyBytes + 60`; ends with `<p class="mm-skeleton">Message truncated</p></div>`; output is valid UTF-8 (String round-trip equals itself) |
| `testDocumentCapStripsOldestCollapsed` | 6 messages each with a 1.4 MB body, `[0,1,2,3]` collapsed, `[4,5]` expanded | `strippedIds == ["m0","m1"]` (2 × 1.4 removed → 5.6 MB ≤ 6 MB); section `m0` contains `mm-stripped` and `Tap to load this message`; `m2` contains its body; `m4`,`m5` never stripped |
| `testDocumentCapNeverStripsExpanded` | 6 messages all expanded, 1.4 MB each | `strippedIds.isEmpty`; all bodies present |
| `testToggleScript` | `toggleScript(messageId: "18f\"x;")` | equals §5.6 with `{id}` = `18fx` |
| `testEmptyDocument` | `empty(L, D)` | equals `render(subject:"", messages:[], …, forcedScheme:nil, imagesAllowed:false)` with the `<h1 …>(No subject)</h1>` line removed; contains `</head><body>\n</body></html>`; no `<section` |
| `testRestoringRemoteImagesIsAnchoredToPlaceholder` | `restoringRemoteImages("<img data-src=\"https://a\" src=\"data:image/gif;base64,OTHER\">")` | unchanged (only the exact placeholder is replaced) |

### 7.3 App tests (`xcodebuild`)

| Test file | Test | Setup | Assertions |
|---|---|---|---|
| `minimailTests/Web/WebViewHostTests.swift` | `testConfigurationFlags` | `WebViewHost.makeConfiguration(cid: CIDSchemeHandler(store: store), bridge: WebBridge())` with `store = InlineImageStore(gmail:…stub, db: TestDatabase.make(), cacheDirectory: temp)` | `defaultWebpagePreferences.allowsContentJavaScript == false`; `.preferredContentMode == .mobile`; `websiteDataStore.isPersistent == false`; `dataDetectorTypes == []`; `suppressesIncrementalRendering == true`; `urlSchemeHandler(forURLScheme: "minimail-cid") != nil`; `userContentController.userScripts.count == 1`, `[0].injectionTime == .atDocumentEnd`, `[0].isForMainFrameOnly == true`, `[0].source == WebBridge.clickDelegateJS` |
| | `testRuleListsCompile` | `RuleLists.reset(); await RuleLists.prepare()` | `RuleLists.blockAll != nil`, `RuleLists.imagesOnly != nil`; second `prepare()` keeps the same object identities |
| | `testRuleListJSONIsValid` | `JSONSerialization.jsonObject(with:)` on both JSON strings | arrays of 4 and 5 dictionaries; every `trigger` has `url-filter`; second rule of images-only has `resource-type == ["image"]` and action `ignore-previous-rules` |
| | `testInstanceSettings` | `host.webView` | `allowsLinkPreview == false`; `isOpaque == false`; `navigationDelegate === host.linkPolicy`; `uiDelegate === host.linkPolicy`; `scrollView.contentInsetAdjustmentBehavior == .automatic` |
| | `testSetImagesAllowedTracksState` | `await RuleLists.prepare()`; `host.setImagesAllowed(true)`; `(false)` | `host.imagesAllowed` toggles; no throw; `removeAllContentRuleLists` compiles (name check — build failure = §10 F3) |
| | `testPrepareWarmsUp` | expectation on `host.linkPolicy.onDidFinish`; `await host.prepare()` | `isPrepared == true`; `didFinish` within 5 s; `host.webView.url?.absoluteString == "about:blank"` |
| | `testLoadAndRecycle` | `host.load(document: ThreadDocument.render(subject:"Seeded subject", …), revision: 1)`; wait didFinish; `evaluateJavaScript("document.querySelector('h1').textContent")` | equals `"Seeded subject"`; then `host.recycle()`; wait didFinish; `evaluateJavaScript("document.querySelectorAll('section').length")` == 0; `loadedRevision == -1` |
| | `testThrowawayHasNoHandlers` | `host.makeThrowawayWebView()` | `configuration.urlSchemeHandler(forURLScheme: "minimail-cid") == nil`; `userContentController.userScripts.isEmpty`; `allowsLinkPreview == false`; `navigationDelegate !== host.linkPolicy` |
| | `testDidLeaveThreadSchedulesRecycle` | `host.recycleDelayOverride = 0.05` (internal test hook) ; `load(…, revision: 3)`; `host.didLeaveThread()`; wait 0.5 s | `loadedRevision == -1` |
| `minimailTests/Web/WebBridgeTests.swift` | `testParseMatrix` | dictionaries | `["action":"toggle","id":"m1"]` → `.toggle("m1")`; `images` → `.loadImages`; `retry` → `.retry`; `["action":"att","id":"m1","part":"2"]` → `.attachment("m1","2")`; `att` without part → nil; `toggle` with `id:""` → nil; `["action":"link"]` → nil; `"string"` → nil |
| | `testParseActionURL` | `URL(string: "minimail-action://att/m1/2")` etc. | `.attachment("m1","2")`; `minimail-action://toggle/m1` → `.toggle`; `minimail-action://toggle/` → nil; `https://x/toggle/m1` → nil |
| | `testClickScriptShape` | — | `clickDelegateJS` contains `messageHandlers.mm.postMessage`, `data-action`, `preventDefault`, `closest('section.mm-msg')` |
| | `testLinkPolicyDecisionMatrix` | `LinkPolicy.decision(for:type:)` | http/https/mailto/tel + `.linkActivated` → (`.cancel`, url, nil); `javascript:` + `.linkActivated` → (`.cancel`, nil, nil); `minimail-action://images/m1` → (`.cancel`, nil, `.loadImages("m1")`); `about:blank` + `.other` → (`.allow`, nil, nil); `https://x` + `.other` → `.cancel`; `about:blank` + `.reload` → `.cancel`; nil url → `.cancel` |
| | `testCIDParse` | `CIDSchemeHandler.parse` | `minimail-cid://m1/ii_logo%40x` → `("m1","ii_logo@x")`; `minimail-cid://m1/` → nil; `minimail-cid:///x` → nil |
| `minimailTests/Web/InlineImageStoreTests.swift` (setup: `StubURLProtocol.reset()`; `db = TestDatabase.make()`; seed message `m1` (thread `m1`) via `TestDatabase.seed`; `db.write { BodyRepository.storeBody($0, messageId: "m1", body: SanitizedBody(html: "<img src=\"minimail-cid://m1/ii_logo\">", hasRemoteImages: false, darkStrategy: .plain, referencedContentIDs: ["ii_logo"]), text: nil, attachments: [ParsedAttachment(partId: "1", filename: "logo.png", mimeType: "image/png", size: 12, contentId: "ii_logo", attachmentId: "att1", inlineData: nil)], referenced: ["ii_logo"], sanitizerVersion: 1, now: 0) }`; `gmail = GmailClient(tokens: FixedTokenProvider(), session: .minimail(protocolClasses: [StubURLProtocol.self]), limiter: RequestLimiter(max: 2), log: nil)`; `store = InlineImageStore(gmail: gmail, db: db, cacheDirectory: temp, clock: { self.now })`; PNG body JSON `{"size":12,"data":"iVBORw0KGgpGQUtF"}`) | `testFetchesAndCaches` | route `GET /gmail/v1/users/me/messages/m1/attachments/att1` → 200 PNG JSON | `bytes(messageId:"m1", contentId:"ii_logo") == (12 PNG bytes, "image/png")`; file `temp/m1/<sha1(ii_logo)>.bin` exists with those bytes, `.mime` == `image/png`; second call → same result and `StubURLProtocol.recorded.count == 1` |
| | `testDiskCacheSurvivesNewStore` | after `testFetchesAndCaches` seed a fresh store on the same directory, no routes | returns bytes, zero requests |
| | `testReresolveOn404` | routes: `att1` → 404 `{"error":{"code":404,…}}`; `GET /gmail/v1/users/me/messages/m1` (query contains `format=full` and `fields=id,payload`) → full message JSON whose part `1` has `attachmentId "att2"` and `Content-ID <ii_logo>`; `att2` → 200 PNG | bytes returned; recorded paths in order `attachments/att1`, `messages/m1`, `attachments/att2`; `BodyRepository.attachment(db,"m1","1").attachmentId == "att2"` |
| | `testSecond404Fails` | `att1` → 404; `messages/m1` → part with `attachmentId "att2"`; `att2` → 404 | throws `GmailError.notFound`; `failureCount == 1` |
| | `testUnknownContentId` | no routes | `bytes("m1","nope")` throws `InlineImageError.unknownContentId`; zero requests; `failureCount == 1` |
| | `testCaseInsensitiveContentId` | route att1 → PNG | `bytes("m1","II_LOGO")` succeeds |
| | `testFailureCachedFor60s` | `att1` → 500 (GmailClient retries then throws `.server`) | first call throws `GmailError.server(500)`; second call throws `InlineImageError.recentlyFailed` with no new request; `now += 61`; third call performs a request |
| | `testInFlightCap` | seed 4 inline attachments `ii_1…ii_4` with ids `a1…a4`; routes with `delay: 0.3` | `async let` 4 fetches; `StubURLProtocol.maxConcurrent <= 2`; all 4 succeed |
| | `testConcurrentSameKeyDedupes` | route att1 delay 0.2 | two concurrent `bytes("m1","ii_logo")` → one request |
| | `testPurge` | after a fetch: `await store.purge()` | directory gone; `failureCount == 0`; next call performs a request again |

`InvariantChecks.assertAll` (06) is called after `testReresolveOn404` (the only test that writes to the database).

---

## 8. Tasks

- [ ] **T08.1 Sanitizer core** — files: `Sources/MailHTML/Sanitizer.swift`, `Sources/MailHTML/StyleScrubber.swift`, `Sources/MailHTML/TrackingPixel.swift`, `Tests/MailHTMLTests/Support/HTMLFixtures.swift`, `Tests/MailHTMLTests/{SanitizerTests,StyleScrubberTests,TrackingPixelTests}.swift`, fixtures `plain-mail.html`, `tracking-pixels.html`, `inline-cid.html`, `xss-samples.html`, `malformed.html`, `newsletter.html`. `DarkStrategyClassifier` is a temporary stub returning `.plain` inside `Sanitizer.swift` until T08.2 (the three classifier assertions of `SanitizerTests` are added in T08.2). Done when every other `SanitizerTests`/`StyleScrubberTests`/`TrackingPixelTests` test passes. Verify: `cd Packages/MailCore && swift test --filter 'SanitizerTests|StyleScrubberTests|TrackingPixelTests'`.
- [ ] **T08.2 Dark strategy classifier** — files: `Sources/MailHTML/DarkStrategyClassifier.swift` (stub removed from `Sanitizer.swift`), `Tests/MailHTMLTests/DarkStrategyClassifierTests.swift`, fixture `dark-native.html`, the `testNewsletterIsCard`/`testPlainMailIsPlain`/`testDarkNativeIsNative` cases. Verify: `swift test --filter 'DarkStrategyClassifierTests|SanitizerTests'`.
- [ ] **T08.3 Signature sanitizer + quote extractor** — files: `Sources/MailHTML/SignatureSanitizer.swift`, `Sources/MailHTML/QuoteExtractor.swift`, `Tests/MailHTMLTests/{SignatureSanitizerTests,QuoteExtractorTests}.swift`, fixture `signature.html`. Verify: `swift test --filter 'SignatureSanitizerTests|QuoteExtractorTests'`.
- [ ] **T08.4 ThreadDocument** — files: `Sources/MailCore/Render/ThreadDocument.swift`, `Tests/MailCoreTests/ThreadDocumentTests.swift`; `Sanitizer.placeholderGIF` re-pointed to `ThreadDocument.placeholderGIF` (and `testPlaceholderMatchesThreadDocument`). Done when all 18 `ThreadDocumentTests` pass on Linux and macOS. Verify: `swift test --filter ThreadDocumentTests` and `make core-test`.
- [ ] **T08.5 WebBridge + LinkPolicy + CID parsing** — files: `minimail/Web/WebBridge.swift`, `minimail/Web/LinkPolicy.swift`, `minimail/Web/CIDSchemeHandler.swift` (parse + handler; `InlineImageStore` may be a compile-only shell with `bytes` throwing `.unknownContentId` until T08.6), `minimailTests/Web/WebBridgeTests.swift`. Verify: `make build && make test-one T=minimailTests/WebBridgeTests`.
- [ ] **T08.6 InlineImageStore** — files: `minimail/Web/InlineImageStore.swift` (full), `minimail/Web/CIDSchemeHandler.swift` (final), `minimailTests/Web/InlineImageStoreTests.swift`. Verify: `make test-one T=minimailTests/InlineImageStoreTests`.
- [ ] **T08.7 WebViewHost + RuleLists + MailWebView** — files: `minimail/Web/WebViewHost.swift`, `minimail/Web/MailWebView.swift`, `minimailTests/Web/WebViewHostTests.swift`. Verify: `make test-one T=minimailTests/WebViewHostTests`; `grep -n 'removeAllContentRuleLists' minimail/Web/WebViewHost.swift` prints one line (or the F3 fallback is applied and noted in §10).
- [ ] **T08.8 AppEnvironment wiring + lint** — files: `minimail/App/AppEnvironment.swift` (`[08]` insertion, `cidCacheDirectory`, step c, wipe tail), `minimailTests/App/AppEnvironmentTests.swift` (add `testWebHostConstructedWithoutWebView`: after `AppEnvironment(testing: true)`, `env.webHost.isPrepared == false` and no `WKWebView` was created — assert through an internal `webViewIfCreated == nil`). Verify: `make build && make test-one T=minimailTests/AppEnvironmentTests && make lint` (`make lint` must not find `^import SwiftSoup` under `Sources/MailCore`, nor raw colours under `minimail/Web`).

---

## 9. Acceptance criteria

1. `make core-test` passes on macOS with every `MailHTMLTests` and `ThreadDocumentTests` case green; on Linux either the same, or `make core-test-nohtml` passes and the SwiftSoup Linux failure is recorded in this spec's §10 (architecture §14 #1).
2. For `xss-samples.html`, the sanitized output contains no `<script`, `<iframe`, `<form`, `<meta`, `<object`, `<base`, `<link`, `<svg`, no `on[a-z]+=` attribute, no `javascript:` and no `target="_blank"` (`SanitizerTests`, T08.1).
3. Every remote `<img>` in sanitized output has `data-src` = original URL immediately followed by `src` = placeholder GIF and class `mm-remote`; every `cid:` image becomes `minimail-cid://<messageId>/<encoded cid>` and its Content-ID appears in `referencedContentIDs` (`SanitizerTests`).
4. Tracking pixels (remote, alt-less, ≤ 2 px or hidden) are removed and never set `hasRemoteImages` (`TrackingPixelTests`, `SanitizerTests`).
5. `darkStrategy` is `.native` for mails declaring colour-scheme support, `.card` for author backgrounds or table+image layouts, `.plain` otherwise (`DarkStrategyClassifierTests`).
6. `ThreadDocument.render` emits the exact CSP for both image modes, the `data-theme` attribute only for `"light"`/`"dark"`, one `<section>` per message with the right classes, restores `data-src` only for allowed messages, caps bodies at 1.5 MB and documents at 6 MB by stripping the oldest collapsed messages, and escapes every header field (`ThreadDocumentTests`).
7. `WebViewHost.makeConfiguration` sets `allowsContentJavaScript = false`, `.mobile`, non-persistent data store, no data detectors, `suppressesIncrementalRendering`, the `minimail-cid` handler, the `mm` message handler and exactly one `.atDocumentEnd` main-frame user script; both rule-list JSON strings compile on the simulator (`WebViewHostTests`).
8. `InlineImageStore` serves from memory, then disk, then `attachments.get`; re-resolves the id exactly once on 404 and persists it via `BodyRepository.updateAttachmentIds`; never has more than 2 requests in flight; caches failures for 60 s; `purge()` removes the cache directory (`InlineImageStoreTests`).
9. `LinkPolicy` allows only the `about:blank` `.other` navigation and cancels everything else, handing http/https/mailto/tel links to `openURL` (`WebBridgeTests.testLinkPolicyDecisionMatrix`).
10. `AppEnvironment(testing: true)` constructs `inlineImages`, `webBridge`, `webHost` without creating a `WKWebView`; `startDeferredWork` calls `webHost.prepare()` ~1 s after the first frame in production (`AppEnvironmentTests`, code inspection: `grep -n 'webHost.prepare' minimail/App/AppEnvironment.swift`).
11. `make lint` passes: no `import SwiftSoup` under `Sources/MailCore`, no UIKit/SwiftUI/WebKit import in either package target, no raw colours in `minimail/Web`.
12. Device checklist items handed to module 14 (`docs/plan/device-checklist.md`), each with the expected outcome: (a) open a newsletter with images off → Safari Web Inspector network tab shows zero requests; (b) tap "Load images" → only `https:` image requests appear, no fonts/CSS; (c) tap a message header → section collapses without a reload (JS bridge works with content JS disabled — §14 #3); (d) Settings → Dark while the system is Light → the document renders dark (`overrideUserInterfaceStyle` or `data-theme` path — §14 #5); (e) a mail with an inline `cid:` image shows it (CSP `img-src minimail-cid:` accepted — §14 #4); (f) tap an `https:` link → Safari opens, the web view stays on the thread.

---

## 10. Open questions & assumptions

| # | Item | Status | Assumption / fallback |
|---|---|---|---|
| A1 | SwiftSoup element/whitelist API names (`parseBodyFragment`, `select`, `attr`, `removeAttr`, `addClass`, `removeClass`, `hasAttr`, `remove`, `Elements.size()`, `outputSettings().prettyPrint(pretty:)`, `Whitelist.relaxed()/addTags/addAttributes/addProtocols/removeProtocols/addCSSProperties/addEnforcedAttribute/preserveRelativeLinks`, 4-argument `clean`) | UNVERIFIED (`[html-rendering §7]`) | Names as in the research snippets and the jsoup port; fixed at first compile, no design impact. |
| A2 | SwiftSoup's `relaxed()` default tag/attribute/protocol set equals jsoup's | assumed | `testTargetEnforcedSelf`/`testSrcsetAndProtocolRelativeDropped` catch differences; adjust `whitelist()` with explicit `addTags` if a tag is missing. |
| A3 | `addProtocols("img","src","minimail-cid")` keeps `minimail-cid://…` under `preserveRelativeLinks(true)` | UNVERIFIED (`testValidProtocol` nuance) | `testCidRewriteSurvivesClean`. Fallback F2: keep `cid` in a temporary allowlisted attribute `data-cid` through `clean`, then a second `parseBodyFragment` pass sets `src` and drops `data-cid`. |
| A4 | Swift 6 + MainActor default accepts `@MainActor` classes conforming to `WKScriptMessageHandler`, `WKURLSchemeHandler`, `WKNavigationDelegate`, `WKUIDelegate` | assumed (`[tooling §3.3]`) | Fallback: declare the conformances `@preconcurrency`, or mark the callbacks `nonisolated` and wrap bodies in `MainActor.assumeIsolated { }` (WebKit documents main-thread delivery). |
| A5 | `WKUserContentController.removeAllContentRuleLists()` exists | UNVERIFIED (`[html-rendering §7]`; architecture §14 #4) | Fallback F3: keep the currently attached list in `WebViewHost.attachedList` and call `remove(_:)`; if that name is also missing, build a second configuration (images-on) and swap the instance for that document. |
| A6 | Architecture §8.4 ("recycle on leave") vs §9.3 ("60 s after leaving") | design choice | Both entry points exist: `recycle()` immediate, `didLeaveThread()` delayed 60 s. Recommendation to module 10: `didLeaveThread()` on disappear (a back-and-forth keeps the DOM; memory warning still recycles when unattached). |
| A7 | `overrideUserInterfaceStyle` propagates into `prefers-color-scheme` inside WKWebView | UNVERIFIED (architecture §14 #5) | Template carries `html[data-theme]` variables and `html:not([data-theme=light])`-guarded dark rules; 10 passes `theme.forcedDocumentTheme`. Device check item (d). |
| A8 | CSP `img-src minimail-cid:` accepted by WebKit for an app-registered scheme | UNVERIFIED (architecture §14 #4) | Device check item (e). Fallback: `csp()` omits `minimail-cid:` (custom-scheme loads never match the rule lists' `^https?://` and are served only by our handler). |
| A9 | Signature preview document (13) | assumption | 13 wraps the sanitized signature as `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'"><style>` + `ThreadDocument.css(light:dark:)` + `</style></head><body class="mm-plain"><div class="mm-body">…</div></body></html>` and loads it in `makeThrowawayWebView()` with the block-all list — remote signature images therefore do NOT render in the preview (consistent with the images-off default); 13 may call `setImagesAllowed`-equivalent logic on its own instance if the owner wants them. |
| A10 | Truncating a 1.5 MB body at a byte boundary may cut inside a tag | accepted | WebKit's parser recovers; the "Message truncated" note is appended as a separate element. Bodies over 1.5 MB after sanitizing are rare (input capped at 2 MiB). |
| A11 | `UIColor(themeTokens.background)` round-trips a dynamic system colour | UNVERIFIED | Stock themes resolve to `UIColor.systemBackground`, which the host applies itself before the first load; `MailWebView` re-applies the token colour on every update. If the conversion loses dynamism, 10 passes `UIColor.systemBackground` for the stock themes (still theme-token-derived, `make lint` grep unaffected). |
| A12 | 500 KB newsletter < 150 ms | performance target (architecture §12.3) | Measured only with `MAILCORE_PERF=1 swift test -c release --filter testNewsletter500KBUnder150ms` on the macOS runner; debug builds of SwiftSoup are slower and are not gated. |
| D1 | `ThreadDocumentMessage.attachments` is `[ThreadDocumentAttachment]` (struct) instead of the architecture's tuple array | DEVIATION | Tuples cannot satisfy `Equatable`/`Sendable` synthesis; same pattern as 06's `ThreadChip`. |
| D2 | `WebMessage.retry(messageId:)` added | DEVIATION (additive) | The §9.2 template has `data-action="retry"`; without a case the bridge could not deliver it. 10 answers it with `BodyRepository.resetUnavailable` + `ensureThreadLoaded`. |
| D3 | `InlineImageStore.init(gmail:db: any DatabaseWriter, …)` instead of `DatabasePool` | DEVIATION | Same as 07 D1: tests use `DatabaseQueue`; the app passes its `DatabasePool`. |
| D4 | `MailWebView` gains `imagesAllowed: Bool` and `backgroundColor: UIColor` | DEVIATION (additive) | The rule-list swap and the themed background must be applied before `loadHTMLString`; making them part of the representable's value guarantees ordering inside one `updateUIView`. |
| D5 | `WebViewHost` additions: `linkPolicy`, `load(document:revision:)`, `didLeaveThread()`, `didAttach()/didDetach()`, `isPrepared`, `imagesAllowed`, `loadedRevision`; `LinkPolicy` additions `onAction`, `onDidFinish`, `WKUIDelegate`; `ThreadDocument` additions `strippedIds`, `css`, `csp`, `restoringRemoteImages`, `placeholderGIF`; `Sanitizer.whitelist()/allowedCSSProperties`; `SignatureSanitizer.hasDataImages/signatureWhitelist`; `TrackingPixel`/`DarkStrategyClassifier` public helpers | ADDITIONS | Needed for testability and for the responsibilities the architecture assigns in prose (signpost `documentLoad`, the document cap's "until expanded", delegate ownership). No architecture signature is changed. |
| D6 | `Sanitizer.placeholderGIF` is defined once in `MailCore` (`ThreadDocument.placeholderGIF`) and re-exported | DEVIATION (placement) | `ThreadDocument.restoringRemoteImages` (MailCore) must match the exact placeholder and MailCore cannot import MailHTML. |
| D7 | Test files `minimailTests/Web/WebBridgeTests.swift`, `minimailTests/Web/InlineImageStoreTests.swift` and `Tests/MailHTMLTests/Support/HTMLFixtures.swift` are not in the architecture's §1.3 tree | ADDITION | Same precedent as 07's `MaintenanceTests`/`BackgroundRefreshTests`. |
| D8 | `AttachmentRecord` lookup by `contentId` uses GRDB's query interface (`AttachmentRecord.filter(Column("messageId") == …).fetchAll`) inside `InlineImageStore` | DEVIATION (rule 3 of architecture §2.1 says only `Store/` holds SELECTs) | 06 exposes `BodyRepository.attachment(_:messageId:partId:)` only (by partId). No SQL string is written; if 06 later adds `BodyRepository.attachments(_:messageId:)`, replace the query-interface call with it (one line). |
| D9 | Dark overrides inside the media query are guarded with `html:not([data-theme=light])` | refinement of §9.2 "same rules duplicated" | Makes a forced Light theme correct even when the `prefers-color-scheme` path stays dark (A7); the variable blocks are exactly as in the architecture. |
| O1 | Whether WebKit calls `decidePolicyFor` for `href="#"` fragment navigations when the click script did not run | open | Harmless either way: `.linkActivated` with `about:blank#` is cancelled by the table in §4.8. Fallback F1 (user scripts not running at all — architecture §14 #3): change the template's action links from `href="#"` to `href="minimail-action://<action>/<id>[/<part>]"`; `LinkPolicy` already routes them through `WebBridge.parse(actionURL:)` to `onAction`, and the toggle then needs a rebuild + reload with `scrollTo` restore (10). |
| O2 | `WKContentRuleListStore.default()` availability inside the `xcodebuild test` host on the simulator | assumed available (writes under the host app's Library) | If `default()` returns nil in tests, `testRuleListsCompile` uses `WKContentRuleListStore(url: temp)` through an internal `RuleLists.storeOverride` hook. |
