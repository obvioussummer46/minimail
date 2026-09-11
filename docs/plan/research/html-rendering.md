# Research: HTML rendering in minimail (WKWebView) and outgoing-mail styling

Date: 2026-09-11. Scope: PLAN.md items "Render HTML in WKWebView (sanitized, remote images blocked, 'load images' button)", "Body wrapped with default font/color CSS; HTML signature appended", "HTML sanitized once on fetch, cached; WKWebView pooled (1 instance reused)".

Verification legend: **[V]** = confirmed against the cited primary source (Apple doc JSON, WebKit/SwiftSoup source, spec source). **[S]** = only seen in search-engine snippets because the page itself was blocked by the egress proxy (litmus.com, emailonacid.com, caniemail.com, webkit.org, developers.google.com, developer.mozilla.org, w3.org, mailchimp.com). **UNVERIFIED** = from memory / not confirmable this session; treat as a hypothesis to test.

Every Swift identifier below that carries [V] was read from `https://developer.apple.com/tutorials/data/documentation/webkit/<symbol>.json` (the JSON that backs the developer.apple.com pages) unless another URL is given.

---

## 0. Recommendation (TL;DR)

| Decision | Choice | Why |
|---|---|---|
| Sanitizer | **SwiftSoup 2.13.9** (SPM, pure Swift) with a custom `Whitelist` + a small regex pass for `<style>` blocks | Real HTML5 parser (jsoup port), allowlist cleaner with per-property inline-CSS filtering already built in; a hand-written tokenizer is the riskier and larger job for a solo app |
| Threat model | Sanitizer = privacy + hygiene, **not** the only security layer. Defense in depth: `allowsContentJavaScript = false` + `WKContentRuleList` that blocks every network load + CSP `<meta>` + `WKWebsiteDataStore.nonPersistent()` + `baseURL: nil` | Any single layer failing still leaves no script and no network |
| Remote images | Sanitizer rewrites `src` → `data-src`, replaces `src` with a 1×1 transparent GIF data URI; "Load images" swaps them back with app JavaScript (which keeps running) and swaps the rule list | No request ever leaves the device unless the user taps |
| Inline `cid:` images | Rewrite to custom scheme `minimail-cid://<messageId>/<contentId>` served by a `WKURLSchemeHandler` from the Gmail `attachments.get` cache | Native, no network for the web view, lazy |
| Dark mode | Never invert. Author the document with `color-scheme: light dark`; if the sanitizer classifies the mail as "plain" (no author background colors) apply dark overrides; otherwise render the mail untouched inside a white "card" | Same principle Apple Mail/Gmail follow: respect sender colors when they set any |
| Scrolling / height | **The WKWebView is the scroller.** Whole thread = one HTML document in the single pooled web view; native SwiftUI only above (nav bar) and below (action toolbar). Do **not** embed N web views inside a SwiftUI `ScrollView` | No height measuring, no re-layout on scroll, one WebContent process, one instance reused as PLAN.md already demands |
| Outgoing styling | One wrapper `<div style="font-family:…;font-size:…px;color:…">` around the typed body; each typed line becomes `<div>…</div>`; signature appended in its own `<div>` inheriting the same style; quoted original in `<blockquote>` outside the styled wrapper | Matches what Gmail/Apple Mail effectively produce; inline styles are the only thing every client honours |
| Performance | Sanitize once on fetch (off main), store sanitized HTML + flags in SQLite; create the pooled WKWebView right after first list paint and warm it; compile rule lists once and look them up by identifier; `isOpaque = false` + themed background to avoid the white flash | Cold path is process launch, not HTML size |

---

## 1. Sanitizing incoming HTML

### 1.1 Options

**Option A — SwiftSoup** (`https://github.com/scinfu/SwiftSoup`)

- Latest tag **2.13.9** (2026-08-26); previous 2.13.8 (2026-08-25), 2.13.7 (2026-07-06) [V, `git ls-remote --tags` and the GitHub tags page].
- `Package.swift` is `swift-tools-version:6.0`, platforms `.iOS(.v13)`, `.macOS(.v10_15)`, single library product `SwiftSoup` [V, raw Package.swift on `master`].
- README dependency line: `.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0")` [V]. For minimail pin the current major: `from: "2.13.9"`.
- Cleaning API (read from `Sources/SwiftSoup.swift` and `Sources/Whitelist.swift` on `master`) [V]:
  - `public func clean(_ bodyHtml: String, _ baseUri: String, _ whitelist: Whitelist) throws -> String?`
  - `public func clean(_ bodyHtml: String, _ whitelist: Whitelist) throws -> String?`
  - `public func clean(_ bodyHtml: String, _ baseUri: String, _ whitelist: Whitelist, _ outputSettings: OutputSettings) throws -> String?`
  - `Whitelist.none()`, `Whitelist.simpleText()`, `Whitelist.basic()`, `Whitelist.basicWithImages()`, `Whitelist.relaxed()` (all `throws` except `none()`).
  - Builders (all chainable, `throws`): `addTags(_ tags: String...)`, `removeTags`, `addAttributes(_ tag: String, _ keys: String...)`, `removeAttributes`, `addProtocols(_ tag: String, _ key: String, _ protocols: String...)`, `removeProtocols`, `addEnforcedAttribute(_ tag:_ key:_ value:)`, `addCSSProperties(_ tag: String, _ properties: String...)`, `removeCSSProperties`, `preserveRelativeLinks(_ preserve: Bool)`, `urlWhitespace(_ mode:)`.
  - Pseudo-tag `":all"` is accepted by `addAttributes` and `addCSSProperties` to apply to every allowed tag [V, source comments and `configuredCSSProperties(for:)`].
  - Inline `style` attributes are **filtered per property**: `safeAttribute` calls `sanitizeStyleAttribute`, which keeps only properties listed via `addCSSProperties`, strips CSS comments, and drops declarations whose value fails `isSafeCSSValue` or whose name is in `isAlwaysUnsafeCSSProperty` [V]. So `style` must be allowed with `addAttributes(":all", "style")` **and** the properties enumerated with `addCSSProperties(":all", …)`; anything not enumerated is dropped.
  - Cleaner semantics (`Sources/Cleaner.swift`) [V]: non-allowlisted **elements are dropped but their child text nodes are kept**; `DataNode`s (the raw contents of `<script>`/`<style>`) are copied only when the parent tag is allowlisted, otherwise discarded; comments and processing instructions are always discarded. `clean()` returns `clean.body()?.html()` — a body fragment; `<head>`, `<meta>`, `<title>` never survive.
  - Consequence: if you allowlist `style` (the element) to keep newsletter CSS, its text is copied **verbatim** — you must scrub it yourself (see 1.4).
  - `relaxed()` allows `img src` only for `http`/`https` protocols; `data:` and `cid:` are rejected unless added with `addProtocols("img", "src", "data", "cid")` [V]. A relative or protocol-less value passes when `preserveRelativeLinks(true)`; otherwise it is resolved against `baseUri` and removed if it cannot be resolved (UNVERIFIED nuance: read `testValidProtocol` before relying on it).

**Option B — hand-written allowlist sanitizer**

- Foundation has no HTML parser (`XMLParser` is strict XML; `NSAttributedString(data:options:[.documentType:.html])` uses WebKit, is slow and main-thread-bound — not usable). You would need either a libxml2 `htmlReadMemory` bridge (C API, module map, error handling of malformed input) or your own tokenizer. A tokenizer that survives real-world mail (unclosed tags, `<!--[if mso]>` blocks, nested tables, attribute quoting variants, entity edge cases, mXSS tricks like `<svg><style>…`) is weeks of work and the class of bug it produces is silent (content lost or, worse, markup reinterpreted).
- Cost/benefit for a solo minimal app: SwiftSoup is ~1 dependency, pure Swift, no transitive deps, builds with SwiftPM from the CLI, and the executor can unit-test the whitelist with XCTest. The hand-written route only wins on binary size (SwiftSoup adds on the order of 1–2 MB, UNVERIFIED) — irrelevant here.

**Recommendation: Option A (SwiftSoup 2.13.9)** plus a ~40-line pre/post pass in Swift for the things a whitelist cannot express (`<style>` scrubbing, image neutralization, tracking-pixel heuristics, `cid:` rewriting).

### 1.2 What to strip / keep

Strip (never allowlisted, so SwiftSoup removes the element; children text is kept, script/style data is dropped): `script`, `noscript`, `iframe`, `frame`, `frameset`, `object`, `embed`, `applet`, `form`, `input`, `button`, `select`, `textarea`, `meta` (incl. `http-equiv="refresh"`), `link` (external CSS), `base`, `template`, `svg`, `math`, `video`, `audio`, `source`, `track`, `canvas`, `dialog`. Attributes: every `on*` handler (never allowlisted), `srcset`, `sizes`, `formaction`, `ping`, `background` on `body/table/td` (URL-bearing; add only with `data`/`minimail-cid` protocols if you want it), `id`/`class` (keep `class` only if you keep `<style>`; see 1.4), `style` properties not in the CSS allowlist (`position`, `behavior`, `-moz-binding`, `expression`, `filter`, `content`, `pointer-events`, `z-index` are deliberately absent).

Keep: inline `style` (filtered), `table/thead/tbody/tfoot/tr/td/th/caption/col/colgroup` with `width/height/align/valign/bgcolor/colspan/rowspan/cellpadding/cellspacing/border`, `img` with `src/alt/width/height/align/title`, `a` with `href/title` (`http`, `https`, `mailto`, `tel`), text formatting and structure (`p div span br hr h1–h6 b i u em strong small sub sup blockquote pre code ul ol li dl dt dd center font`). `font` with `face/size/color` is still common in mail — keep it.

Protocol policy: `a href` → `http`, `https`, `mailto`, `tel`; `img src` → `data` (only the placeholder you inject), `minimail-cid`; remote `http(s)` `src` values are moved to `data-src` **before** cleaning so the whitelist never sees them (see 1.3).

### 1.3 Remote-image neutralization and the "Load images" button

Pipeline (runs once, on fetch, off the main actor):

1. Parse with SwiftSoup (`SwiftSoup.parseBodyFragment(html, "")` — declared `public func parseBodyFragment(_ bodyHtml: String, _ baseUri: String) throws -> Document` [V]).
2. For every `img[src]` (and `[background]`):
   - `cid:xxx` → `minimail-cid://<gmailMessageId>/<xxx>` (percent-encode `xxx`; Content-ID may contain `@`, `.`).
   - `data:image/…` → keep (inline, no network). Reject any other `data:` MIME.
   - `http(s)://…` → set `data-src` = original, set `src` = placeholder GIF, add `class="mm-remote"`. Record `hasRemoteImages = true`.
   - Anything else (`file:`, `ftp:`, `javascript:`, unknown) → drop the attribute.
3. Tracking-pixel heuristic (1.5): if it fires, **remove** the element instead of neutralizing.
4. Run the Cleaner with the whitelist below (this is what drops scripts, handlers, forms, meta refresh, `javascript:` URLs, unknown protocols).
5. Scrub allowlisted `<style>` text with the regex pass (1.4).
6. Store: `body_html` (sanitized fragment), `has_remote_images` (Bool), `dark_strategy` (`plain` | `card`, see §3), `sanitizer_version` (Int; bump to force re-sanitize from the API instead of storing raw HTML).

```swift
import SwiftSoup

enum Sanitizer {
    static let version = 1
    // 1x1 transparent GIF
    static let placeholder = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    struct Output { var html: String; var hasRemoteImages: Bool; var darkStrategy: DarkStrategy }

    static func whitelist() throws -> Whitelist {
        let w = try Whitelist.relaxed()
            .addTags("center", "font", "hr", "s", "del", "ins", "abbr", "address", "style", "wbr")
            .addAttributes(":all", "style", "class", "dir", "lang", "align", "valign", "width", "height", "bgcolor", "border", "cellpadding", "cellspacing")
            .addAttributes("img", "data-src")
            .addAttributes("font", "face", "size", "color")
            .addAttributes("a", "href", "title")
            .addAttributes("blockquote", "type")
            .addProtocols("a", "href", "http", "https", "mailto", "tel")
            .addProtocols("img", "src", "data", "minimail-cid")
            .addCSSProperties(":all",
                "color", "background", "background-color", "font", "font-family", "font-size", "font-weight", "font-style",
                "text-decoration", "text-align", "line-height", "letter-spacing", "vertical-align", "white-space",
                "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
                "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
                "border", "border-top", "border-right", "border-bottom", "border-left", "border-collapse", "border-spacing", "border-radius", "border-color", "border-width", "border-style",
                "width", "min-width", "max-width", "height", "max-height", "display", "float", "clear", "overflow", "word-break", "word-wrap", "overflow-wrap", "table-layout", "list-style", "list-style-type", "text-transform", "text-indent", "direction", "unicode-bidi", "mso-hide")
            .preserveRelativeLinks(true)
        // relaxed() enforces nothing on <a>; add rel/target so taps go through decidePolicyFor, never a new window
        try w.addEnforcedAttribute("a", "target", "_self")
        return w
    }

    static func sanitize(rawHTML: String, gmailMessageId: String) throws -> Output {
        let doc = try SwiftSoup.parseBodyFragment(rawHTML, "")
        var hasRemote = false
        for img in try doc.select("img") {
            let src = try img.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            if isTrackingPixel(img, src: src) { try img.remove(); continue }
            if src.lowercased().hasPrefix("cid:") {
                let cid = String(src.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                try img.attr("src", "minimail-cid://\(gmailMessageId)/\(cid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cid)")
            } else if src.lowercased().hasPrefix("data:image/") {
                // keep
            } else if src.lowercased().hasPrefix("http://") || src.lowercased().hasPrefix("https://") {
                try img.attr("data-src", src).attr("src", placeholder).addClass("mm-remote")
                hasRemote = true
            } else {
                try img.removeAttr("src")
            }
            try img.removeAttr("srcset"); try img.removeAttr("sizes"); try img.removeAttr("loading")
        }
        for el in try doc.select("[background]") { try el.removeAttr("background") } // stage 1: drop, don't neutralize
        let strategy = DarkStrategy.classify(doc)          // §3.3
        let bodyHTML = try doc.body()?.html() ?? ""
        guard var clean = try SwiftSoup.clean(bodyHTML, "", try whitelist()) else { return Output(html: "", hasRemoteImages: false, darkStrategy: .plain) }
        clean = StyleScrubber.scrub(clean)                  // §1.4
        return Output(html: clean, hasRemoteImages: hasRemote, darkStrategy: strategy)
    }
}
```

Notes for the executor:
- `doc.select`, `attr`, `removeAttr`, `addClass`, `remove()` are the standard jsoup-style element API SwiftSoup exposes (UNVERIFIED exact signatures this session; they are used in the README examples).
- Because `clean()` re-parses the fragment through the whitelist, every `on*`, `javascript:` href, `<script>`, `<iframe>`, `<meta http-equiv=refresh>`, `<form>`, `<link>` is removed there; steps 2–3 only need to touch images.
- `addEnforcedAttribute("a","target","_self")`: a `target="_blank"` link creates a new-window request that goes to `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)` instead of `decidePolicyFor` (UNVERIFIED for JS-disabled pages; enforcing `_self` sidesteps the question).

"Load images" button (per message, shown when `has_remote_images`):

```swift
// App JavaScript keeps running with allowsContentJavaScript = false (WWDC20 10188, quoted in §2.1)
let restoreJS = """
for (const img of document.querySelectorAll('img.mm-remote[data-src]')) { img.src = img.dataset.src; }
"""
func loadRemoteImages(in webView: WKWebView, for messageId: String) async throws {
    let ucc = webView.configuration.userContentController
    ucc.removeAllContentRuleLists()            // UNVERIFIED name; see §2.2
    ucc.add(RuleLists.imagesOnly)              // still blocks script/style-sheet/font/media/raw…
    _ = try await webView.evaluateJavaScript(restoreJS)
}
```
Because the document carries a CSP `<meta>` with `img-src data: minimail-cid:` (§2.3), that CSP would still block `https:` images after the swap. Therefore the document template has two CSP variants; when the user opts in, **reload** the document with the `images-on` CSP and the images-only rule list rather than mutating in place. Reload is cheap (local string), and it also gives you a clean way to persist "images allowed for this sender" later. Keep the JS-swap approach only if you decide not to use a CSP meta at all.

### 1.4 `<style>` blocks

Gmail itself supports `<style>` blocks (with class/element/id selectors) [S — `https://developers.google.com/workspace/gmail/design/css`, page blocked, statement from search snippet], so most newsletters depend on them. Keep the element, but since the Cleaner copies its `DataNode` verbatim, scrub it:

```swift
enum StyleScrubber {
    // Applied to the whole sanitized fragment; only <style> contents contain these tokens after cleaning.
    static let patterns: [String] = [
        #"@import[^;]*;"#,                       // external CSS
        #"@font-face\s*\{[^}]*\}"#,              // remote fonts (also blocked by rule list; belt and braces)
        #"url\s*\((?!\s*['"]?data:)[^)]*\)"#,    // any non-data url() -> removes remote background images / trackers
        #"expression\s*\("#, #"behavior\s*:"#, #"-moz-binding\s*:"#, #"javascript:"#,
        #"position\s*:\s*fixed"#, #"position\s*:\s*absolute"#   // keep the mail inside its box
    ]
    static func scrub(_ html: String) -> String {
        var out = html
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}
```
This regex pass is deliberately crude: with `allowsContentJavaScript = false`, the rule list and the CSP in place, CSS cannot exfiltrate anything; the scrub only stops layout-breaking rules. A `@media (prefers-color-scheme: dark)` block from the sender is kept — that is exactly what §3 wants.

### 1.5 Tracking-pixel heuristics

Reference implementations: MailTrackerBlocker (Apple Mail plug-in) uses a list of ~300 vendor patterns plus one generic heuristic regex [V, `Source/MTBBlockedMessage.m`]:

```
kGenericSpyPixelRegex = "<img[^>]+(width\s*=["'\s]*[01]p?x?["'\s]|[^-]width:\s*[01]px)+[^>]*>"
```
i.e. an `<img>` whose `width` attribute or inline `width:` is 0 or 1. PixelGuard (Thunderbird) describes "1x1/hidden images, suspicious tracking parameters, and externally hosted assets" without publishing thresholds [V, repo README]. Academic work notes senders evade pure 1×1 checks with slightly larger images [S].

Rule for minimail (only applied to **remote** images; inline `data:`/`cid:` images are never trackers):

```swift
static func isTrackingPixel(_ img: Element, src: String) -> Bool {
    guard src.lowercased().hasPrefix("http") else { return false }
    func dim(_ name: String) -> Int? {
        let v = (try? img.attr(name)) ?? ""
        return Int(v.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces))
    }
    let style = ((try? img.attr("style")) ?? "").lowercased().replacingOccurrences(of: " ", with: "")
    func cssDim(_ name: String) -> Int? {
        guard let r = style.range(of: "\(name):") else { return nil }
        let tail = style[r.upperBound...].prefix { $0.isNumber }
        return Int(tail)
    }
    let w = dim("width") ?? cssDim("width"); let h = dim("height") ?? cssDim("height")
    let tiny = (w != nil && w! <= 2) || (h != nil && h! <= 2) || (w == 0 || h == 0)
    let hidden = style.contains("display:none") || style.contains("visibility:hidden") || style.contains("opacity:0")
    let sneaky = ((try? img.attr("alt")) ?? "").isEmpty && (tiny || hidden)
    return sneaky
}
```
Do not add a vendor domain list in stage 1: with images off by default nothing loads anyway; the heuristic exists so that "Load images" does not fire the obvious beacons. Keep `alt`-less tiny images out even after opt-in.

---

## 2. WKWebView hardening

### 2.1 JavaScript off for content, on for the app

- `WKWebpagePreferences.allowsContentJavaScript: Bool` — iOS 14+, default `true`. "If you change the value to false, the web view doesn't execute JavaScript code referenced by the web content. That includes JavaScript code found in inline `<script>` elements, `javascript:` URLs, and all other referenced JavaScript content." [V]
- `WKPreferences.javaScriptEnabled` is deprecated since iOS 14 with the note "Use WKWebpagePreferences.allowsContentJavaScript to disable content JavaScript on a per-navigation basis"; its discussion says "This setting does not affect user scripts." [V]
- WWDC20 session 10188 (`https://developer.apple.com/videos/play/wwdc2020/10188/`): "By using the allowsContentJavaScript setting on WKWebPagePreferences, you disable only the JavaScript that comes from the web page content itself. In-line scripts, remotely referenced JavaScript files, JavaScript URLs, everything. But your application's JavaScript will continue working." [V] → `evaluateJavaScript`, `callAsyncJavaScript`, `WKUserScript` and `window.webkit.messageHandlers` keep working, which is what the "Load images" swap and the header-tap bridge rely on.
- `WKWebViewConfiguration.defaultWebpagePreferences: WKWebpagePreferences!` (iOS 13+) is where you set it globally [V]. `WKWebpagePreferences.preferredContentMode` (iOS 13+; default `.recommended`) — set `.mobile` so `-webkit-text-size-adjust` behaves the same on iPad as on iPhone [V doc; iPad behaviour from `https://developer.apple.com/forums/thread/723008`].

### 2.2 Content rule list (network kill-switch)

APIs [V]:
- `WKContentRuleListStore` (iOS 11+): "Each store object stores its existing rules persistently in the file system and loads those rules at creation time. A store object doesn't automatically apply any of its rules to a particular web view. To apply a rule to a web view, add it to the WKUserContentController object of the web view's configuration object."
- `func compileContentRuleList(forIdentifier identifier: String!, encodedContentRuleList: String!) async throws -> WKContentRuleList?` — "If a list with the specified identifier already exists in the store, this method overwrites the old rule list with the new content."
- `func contentRuleList(forIdentifier identifier: String!) async throws -> WKContentRuleList?` (Swift async form of `lookUpContentRuleList(forIdentifier:completionHandler:)`).
- `WKUserContentController.add(_ contentRuleList: WKContentRuleList)` (iOS 11+).
- `remove(_ contentRuleList:)` / `removeAllContentRuleLists()` on `WKUserContentController`: UNVERIFIED this session (not fetched) — the executor should confirm in the SDK headers before relying on them; the reload-with-a-fresh-configuration path in §1.3 does not need them.

JSON grammar [V, Apple "Creating a content blocker" + WebKit `Source/WebCore/contentextensions/ContentExtensionParser.cpp` on `main`]:
- Array of `{ "trigger": {...}, "action": {...} }`. `trigger` **must** contain `url-filter` (regex). Other trigger keys parsed by WebKit: `url-filter-is-case-sensitive`, `top-url-filter-is-case-sensitive`, `frame-url-filter-is-case-sensitive`, `resource-type`, `load-type`, `load-context`, `request-method`, `if-domain`, `unless-domain`, `if-top-url`, `unless-top-url`, `if-frame-url`, `unless-frame-url`.
- `action` has only `type` and `selector` fields; `selector` is required for `css-display-none` [V Apple]. Action types WebKit parses: `block`, `ignore-previous-rules`, `ignore-following-rules`, `block-cookies`, `css-display-none`, `make-https`, `notify`, `redirect`, `modify-headers` [V WebKit source].
- `resource-type` values documented by Apple/WebKit: `document`, `image`, `style-sheet`, `script`, `font`, `raw`, `svg-document`, `media`, `popup` [S — WebKit blog 3476 blocked; Apple's archived Content Blocker guide only shows `image`/`script` examples]. Newer values `ping`, `fetch`, `websocket`, `other`: UNVERIFIED. `load-type` values `first-party` / `third-party` [S]. Omit `resource-type` to match every type.
- `url-filter` regex subset (WebKit blog): `.`, `*`, `+`, `?`, `[a-z]` ranges, `^`, `$` — no alternation groups [S]. Use several rules instead of `(a|b)`.

Two lists, compiled once at launch (identifiers are stable, the store persists compiled bytecode):

`block-all.json` — default: nothing but the document itself and custom schemes:
```json
[
  { "trigger": { "url-filter": "^https?://" }, "action": { "type": "block" } },
  { "trigger": { "url-filter": "^wss?://" },   "action": { "type": "block" } },
  { "trigger": { "url-filter": "^ftp://" },    "action": { "type": "block" } },
  { "trigger": { "url-filter": "^file://" },   "action": { "type": "block" } }
]
```
`images-only.json` — after the user taps "Load images": allow only image loads over HTTPS, keep blocking everything else (no fonts, no CSS, no media, no beacons):
```json
[
  { "trigger": { "url-filter": "^https?://" }, "action": { "type": "block" } },
  { "trigger": { "url-filter": "^https://", "resource-type": ["image"] }, "action": { "type": "ignore-previous-rules" } },
  { "trigger": { "url-filter": "^wss?://" },   "action": { "type": "block" } },
  { "trigger": { "url-filter": "^ftp://" },    "action": { "type": "block" } },
  { "trigger": { "url-filter": "^file://" },   "action": { "type": "block" } }
]
```
(`ignore-previous-rules` cancels the earlier `block` for matching loads; "Safari evaluates all the triggers, and executes the actions in order" [V Apple]. Plain-`http://` images stay blocked; mixed content is not worth it.)

```swift
enum RuleLists {
    static var blockAll: WKContentRuleList!
    static var imagesOnly: WKContentRuleList!

    static func prepare() async throws {
        let store = WKContentRuleListStore.default()!
        blockAll   = try await load(store, id: "minimail.block-all.v1",   json: blockAllJSON)
        imagesOnly = try await load(store, id: "minimail.images-only.v1", json: imagesOnlyJSON)
    }
    private static func load(_ store: WKContentRuleListStore, id: String, json: String) async throws -> WKContentRuleList {
        if let existing = try await store.contentRuleList(forIdentifier: id) { return existing }
        guard let compiled = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else {
            throw NSError(domain: "minimail.rulelist", code: 1)
        }
        return compiled
    }
}
```
Bump the identifier suffix whenever the JSON changes (the store keys by identifier).

Does a content rule list apply to `data:` and custom-scheme loads? Rules are matched against the URL string, and neither `data:` nor `minimail-cid:` matches `^https?://`, so they pass. That the rule engine even sees `data:` URLs is UNVERIFIED and irrelevant with these patterns.

### 2.3 CSP meta tag

CSP can be delivered in `<meta http-equiv="Content-Security-Policy" content="…">`; the spec notes "Authors are strongly encouraged to place `<meta>` elements as early in the document as possible", and that `Content-Security-Policy-Report-Only`, `report-uri`, `frame-ancestors` and `sandbox` are **not** supported inside `<meta>` [V, `https://github.com/w3c/webappsec-csp/blob/main/index.bs` ("Neither are the `report-uri`, `frame-ancestors`, and `sandbox` directives")]. Scheme sources such as `data:` and custom `minimail-cid:` are valid source expressions (CSP3 `scheme-source`) [V spec grammar; behaviour with app-registered schemes in WebKit UNVERIFIED — test once].

Images off (default):
```html
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
```
Images on (after opt-in, document is reloaded):
```html
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; img-src https: data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
```
`style-src 'unsafe-inline'` is required for inline `style=""` attributes and `<style>` blocks; `default-src 'none'` covers script/font/media/frame/connect/object. Put it as the **first** child of `<head>`. It is the third layer — not needed for correctness if the rule list works, but it costs nothing and also covers `data:`-scheme edge cases the rule list does not see.

### 2.4 Configuration checklist (one pooled instance)

```swift
@MainActor
func makeMailWebView() -> WKWebView {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false          // [V] iOS 14+
    config.defaultWebpagePreferences.preferredContentMode = .mobile            // [V] iOS 13+
    config.websiteDataStore = .nonPersistent()                                 // [V] in-memory only: no cookies/cache on disk
    config.dataDetectorTypes = []                                              // [V] default is none anyway (iOS 10+)
    config.allowsInlineMediaPlayback = false                                   // media is stripped; irrelevant but explicit
    config.ignoresViewportScaleLimits = false                                  // [V] default; honours viewport user-scalable
    config.setURLSchemeHandler(CIDSchemeHandler(), forURLScheme: "minimail-cid") // [V] iOS 11+
    config.userContentController.add(RuleLists.blockAll)                       // [V]
    config.userContentController.add(HeaderTapHandler.shared, name: "mm")      // window.webkit.messageHandlers.mm.postMessage(...)
    config.suppressesIncrementalRendering = true                               // [V] paint only when fully loaded (local HTML, so ~free)

    let wv = WKWebView(frame: .zero, configuration: config)
    wv.allowsLinkPreview = false                                               // [V] iOS 9+; default true since iOS 10 — off: no peek, no Safari pop
    wv.isOpaque = false                                                        // UIView; with backgroundColor avoids the white flash (forum 121139)
    wv.backgroundColor = UIColor(themeBackground)
    wv.underPageBackgroundColor = UIColor(themeBackground)                     // [V] iOS 15+; overscroll area
    wv.scrollView.contentInsetAdjustmentBehavior = .automatic
    wv.navigationDelegate = LinkPolicy.shared
    #if DEBUG
    wv.isInspectable = true                                                    // [V] iOS 16.4+; Safari Web Inspector
    #endif
    return wv
}
```

- Text selection/long-press: `WKPreferences.isTextInteractionEnabled` (iOS 14.5+, default true) disables **all** text interaction including selection [V]. Apple Mail lets users select text, so leave it `true`; disable only link previews (`allowsLinkPreview = false`). If you also want to suppress the image/link long-press callout without killing selection, inject CSS `a, img { -webkit-touch-callout: none; }` in the template.
- Zoom: WKWebView honours `user-scalable=no` unless `ignoresViewportScaleLimits == true` ("When set to true, this property overrides the `user-scalable` HTML property … The default value of this property is false.") [V]. Recommendation: **allow pinch-zoom** (accessibility, wide tables): viewport `width=device-width, initial-scale=1`. If you want Apple-Mail-like text scaling without page zoom use `webView.pageZoom` (iOS 14+, "equivalent to setting the CSS zoom property on all page content") [V] tied to Dynamic Type.
- `mediaType` (iOS 14+) [V] — leave `nil` (`screen`).
- Process pool: `WKProcessPool` and `WKWebViewConfiguration.processPool` are deprecated since iOS 15 — "Creating and using multiple instances of WKProcessPool no longer has any effect." [V] Nothing to do.
- Base URL: `loadHTMLString(_ string: String, baseURL: URL?)` [V]. Pass `nil` → the document has an opaque `about:blank` origin; relative URLs cannot resolve to anything (good). Do not use `loadFileURL(_:allowingReadAccessTo:)` for bodies — it grants file read access.
- `limitsNavigationsToAppBoundDomains` (iOS 14+) [V] exists but is aimed at app-bound-domain web content; not needed since every navigation is cancelled (2.5).

### 2.5 Navigation policy: open links outside

```swift
final class LinkPolicy: NSObject, WKNavigationDelegate {
    static let shared = LinkPolicy()
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {   // [V] async form
        guard let url = navigationAction.request.url else { return .cancel }
        switch navigationAction.navigationType {                                                                                   // [V] WKNavigationType
        case .linkActivated:
            if ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                await UIApplication.shared.open(url)          // Safari / Mail / Phone; later: SFSafariViewController for http(s)
            }
            return .cancel
        case .other:
            // the initial loadHTMLString navigation is about:blank; allow only that
            return url.absoluteString == "about:blank" ? .allow : .cancel
        default:
            return .cancel                                     // back/forward, reload, form submits, form resubmits
        }
    }
}
```
"If your delegate object implements the `webView(_:decidePolicyFor:preferences:decisionHandler:)` method, the web view doesn't call this method." [V] — implement only one of the two.

### 2.6 `cid:` inline images via `WKURLSchemeHandler`

- `setURLSchemeHandler(_:forURLScheme:)`: scheme names "must start with an ASCII letter, and may contain only ASCII letters, numbers, the '+' character, the '-' character, and the '.' character"; "It is a programmer error to register a handler for a scheme WebKit already handles" and to register the same scheme twice; Apple asks you to "include the name of your app or company in any custom scheme names" [V]. Hence `minimail-cid`, not `cid`.
- `WKURLSchemeTask`: call `didReceive(_ response: URLResponse)`, then `didReceive(_ data: Data)` (one or more times), then `didFinish()`; on error `didFailWithError(_:)` [V]. Implement `webView(_:start:)` / `webView(_:stop:)`.
- Data source: Gmail `users.messages.attachments.get` — `GET gmail/v1/users/{userId}/messages/{messageId}/attachments/{id}`, response `MessagePartBody { attachmentId, size, data (base64url) }`; `gmail.modify` is among the accepted scopes [V, Gmail discovery document]. Which part is which: walk `payload.parts` (each `MessagePart` has `partId, mimeType, filename, headers, body, parts` [V]); a part whose `headers` contain `Content-ID: <xyz>` (and usually `Content-Disposition: inline`) maps `cid:xyz` → `body.attachmentId`. Store `(message_id, content_id, attachment_id, mime)` in the `attachment` table, download on first request from the scheme handler, cache the bytes in the app's Caches directory.

```swift
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let msgId = url.host,
              let cid = url.path.dropFirst().removingPercentEncoding else { task.didFailWithError(URLError(.badURL)); return }
        Task {
            do {
                let (data, mime) = try await InlineImageStore.shared.bytes(messageId: msgId, contentId: cid) // cache → attachments.get
                let resp = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
                task.didReceive(resp); task.didReceive(data); task.didFinish()
            } catch { task.didFailWithError(error) }
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { /* cancel the Task if you keep it */ }
}
```
(Keep track of stopped tasks: calling `didReceive`/`didFinish` on a task after `stop` is a programmer error — UNVERIFIED wording, but that is WebKit's documented contract in the header.)

### 2.7 Document template (viewport, text-size, base CSS)

```html
<!doctype html><html><head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: minimail-cid:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<style>
:root { color-scheme: light dark; }
html { -webkit-text-size-adjust: 100%; }                     /* no auto text inflation; we control size */
body { margin: 0; padding: 12px 16px; font: -apple-system-body; font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif;
       word-wrap: break-word; overflow-wrap: break-word; -webkit-touch-callout: none; }
img { max-width: 100% !important; height: auto; }
table { max-width: 100% !important; }                       /* max-width beats the width="600" attribute */
pre { white-space: pre-wrap; }
blockquote[type=cite] { margin: 0 0 0 .8ex; border-left: 2px solid #8e8e93; padding-left: 1ex; }
.mm-remote { min-width: 1px; min-height: 1px; }
</style>
</head><body class="mm-plain">   <!-- or class="mm-card"; see §3 -->
<div class="mm-msg" data-id="…">…sanitized fragment…</div>
</body></html>
```
- `-webkit-text-size-adjust: 100%` prevents WebKit from inflating text in wide layouts; with `preferredContentMode = .mobile` it behaves identically on iPad [V forum 723008 fix; exact inflation rules UNVERIFIED].
- `font: -apple-system-body` gives Dynamic Type sizing for text that has no author size (UNVERIFIED that WKWebView re-lays out on Dynamic Type change without reload; reload on `UIContentSizeCategory.didChangeNotification` to be safe).
- `viewport-fit=cover` only matters if the web view extends under the home indicator; harmless otherwise.
- Wide fixed layouts: `max-width:100% !important` on `table`/`img` keeps most 600-px newsletters inside the viewport; if a mail still overflows, the web view scrolls horizontally (pinch-zoom allowed) — same behaviour as Apple Mail. `shrink-to-fit=yes` is not used because it shrinks text below readable size.

---

## 3. Dark mode for email

### 3.1 What the big clients do (and why "invert" is wrong)

- Author-declared support: the HTML spec defines `<meta name="color-scheme" content="…">` — "The value must be a string that matches the syntax for the CSS 'color-scheme' property value. It determines the page's supported color-schemes." and "There must not be more than one meta element with its name attribute value set to … color-scheme per document." [V, `https://github.com/whatwg/html/blob/main/source`].
- Apple Mail's contract for **senders**: "Apple Mail 12 (macOS Mojave) requires `<meta name="supported-color-schemes" value="light dark">`; Apple Mail 13+ (macOS Catalina and above) requires `:root { color-scheme: light dark; }`" [V, `https://github.com/hteumeuleu/email-bugs/issues/104`]. With the declaration present Apple Mail "will keep the button dark but they will also flip the body background" [V, `https://github.com/matthieuSolente/email-darkmode`]. Search snippets of Litmus/Email on Acid/Mailchimp add: Apple Mail leaves colours alone when no declaration is present; with the meta tags but no dark styles it applies a *partial* invert (light backgrounds → dark, dark text → light); pure `#FFFFFF`/`#000000` are auto-flipped, hence the `#FFFFFE`/`#010101` trick [S — pages blocked].
- Gmail apps (iOS/Android): apply their own colour transformation ("full colour invert"-like on light sections) and **ignore `prefers-color-scheme`** [S — `https://mailtester.com/blog/gmail-app-dark-mode-color-changes/`, `https://www.mailmode.app/learn/gmail-dark-mode-email-rendering-guide`, both blocked].
- `@media (prefers-color-scheme: dark)` is honoured by Apple Mail and (partially, version-dependent) Outlook; Gmail does not honour it [V matthieuSolente; S others].

Take-away for a **receiving** client we control: (1) inversion filters (`filter: invert(1) hue-rotate(180deg)`) wreck images and brand colours and are what people complain about in Gmail — do not use them; (2) an HTML mail that declares `color-scheme` / has its own `prefers-color-scheme` rules already knows how to be dark — just let WebKit apply it; (3) a mail with author-set backgrounds must be shown as designed, on a light card; (4) a "plain" mail (no backgrounds, default text colours) is safe to recolour.

### 3.2 CSS that gives readable dark rendering

The pooled web view inherits the app's trait collection, so `prefers-color-scheme: dark` follows the theme (set `webView.overrideUserInterfaceStyle` from `ThemeStore` so a forced Light/Dark theme also wins inside the web view — standard `UIView` API; propagation into WebKit media queries is UNVERIFIED but is the documented purpose of the property).

```css
/* always present */
:root { color-scheme: light dark; }
body { background: transparent; }            /* the UIView background (theme.bg) shows through: no flash, no seam */

/* 'plain' strategy: the mail has no author background colours -> recolour text and links */
@media (prefers-color-scheme: dark) {
  body.mm-plain { color: #E5E5EA; }                                    /* iOS label colour on dark */
  body.mm-plain a { color: #0A84FF; }                                  /* iOS systemBlue (dark) */
  body.mm-plain blockquote[type=cite] { border-left-color: #636366; }
  body.mm-plain [style*="color"] { color: inherit !important; }         /* sender's dark-grey text tweaks become unreadable on dark; neutralise */
  body.mm-plain font[color] { color: inherit !important; }
  body.mm-plain hr { border-color: #3A3A3C; }
}

/* 'card' strategy: author set backgrounds -> keep the mail exactly as designed on a white card */
@media (prefers-color-scheme: dark) {
  body.mm-card { padding: 0; }
  body.mm-card .mm-msg { background: #FFFFFF; color: #000000; color-scheme: light;   /* WebKit renders form controls/scrollbars light inside */
                         border-radius: 12px; margin: 12px 16px; padding: 12px; overflow: hidden; }
}
```
Notes:
- `[style*="color"] { color: inherit !important }` in the plain strategy is intentionally blunt: it also catches `background-color`, but by definition the plain strategy is only chosen when no background colours exist. It keeps the sender's font/size/bold; only colour is normalised. Links written as `<a style="color:#1155cc">` fall back to the dark-mode blue.
- If the sender ships `@media (prefers-color-scheme: dark)` rules and a `color-scheme` meta/CSS, classify as `card` **only if** they set backgrounds and did not declare dark support; a sender that declared `color-scheme: light dark` gets `plain` treatment without our colour overrides (add `body.mm-native` that applies nothing) — their own dark CSS does the work.

### 3.3 Classification rule (sanitizer, cached in SQLite as `dark_strategy`)

```swift
enum DarkStrategy: String { case plain, card, native
    static func classify(_ doc: Document) -> DarkStrategy {
        let html = (try? doc.body()?.html()) ?? ""
        let lower = html.lowercased()
        let declaresDark = lower.contains("prefers-color-scheme") || lower.contains("color-scheme:") || lower.contains("supported-color-schemes")
        if declaresDark { return .native }
        let hasBackground = lower.range(of: #"background(-color)?\s*:\s*(?!transparent|none|inherit)"#, options: .regularExpression) != nil
                         || lower.contains("bgcolor=") || lower.contains("background=")
        let imageHeavy = ((try? doc.select("img").count) ?? 0) >= 3
        let tableLayout = ((try? doc.select("table").count) ?? 0) >= 2
        return (hasBackground || (imageHeavy && tableLayout)) ? .card : .plain
    }
}
```
Rule of thumb this encodes: **fall back to the white card whenever the author painted any background** (or built a table-and-images layout, which almost always implies brand colours); otherwise recolour. Plain-text mails (`text/plain` only) never touch this path — render them as `<pre style="white-space:pre-wrap">`-like `<div>`s with the plain strategy.

---

## 4. Content height vs. web view as scroller

Facts:
- Height measurement inside a SwiftUI `ScrollView` requires reading `document.documentElement.scrollHeight` after `didFinish` and binding it to `.frame(height:)` (`https://github.com/Asperi-Demo/4SwiftUI/blob/master/Answers/WKWebView_content_height_in_ScrollView.md`), or KVO on `scrollView.contentSize`, or a JS `ResizeObserver` posting to a `WKScriptMessageHandler`; an Apple-forums thread on the topic (`https://developer.apple.com/forums/thread/816838`) recommends the message-handler route and notes `document.body.scrollHeight` "often provides incorrect values" and that images/late layout make heights arrive incrementally [V forum summary].
- Every measurement fires a SwiftUI re-layout; with several messages that is N web views × M layout passes, plus nested scrolling conflicts (`scrollView.isScrollEnabled = false` on each) and the RunningBoard log noise Apple confirmed for multiple simultaneous web views ("This error is log noise" — FB13464160, `https://developer.apple.com/forums/thread/742739`) [V].
- WKWebView memory is out-of-process: "WKWebView performs all of its work out of process and its memory usage is accounted for separately from that of your app. While it's possible that the WKWebView process could exceed its memory budget, doing so would not cause your app to be terminated and should at most result in a blank view." (Apple Frameworks Engineer, `https://developer.apple.com/forums/thread/21956`) [V] — but each extra web view is still a heavy object, and PLAN.md already fixes "WKWebView pooled (1 instance reused)".

**Recommendation: the web view is the scroller; one document per thread.**

```
NavigationStack
 └─ ThreadScreen (SwiftUI)
     ├─ .navigationTitle(subject)                       native
     ├─ MailWebView (UIViewRepresentable, 1 pooled WKWebView, fills the screen)
     │    └─ HTML document = [ msg header (HTML, system font) + sanitized body ] × N, collapsed except the last
     └─ .toolbar(.bottomBar) { Reply all | Forward | Archive | Read/Unread }   native
```
- Message headers (from/date/to, collapsed-preview) are rendered in HTML with `font: -apple-system-body`, styled with the theme tokens injected as CSS custom properties (`--mm-bg`, `--mm-text`, `--mm-secondary`, `--mm-accent` from `ThemeStore`), so they look native and cost nothing to lay out.
- Interactions: a tap on a header calls `window.webkit.messageHandlers.mm.postMessage({type:'toggle', id})` (app JS is allowed) [V message-handler syntax]; the app records expanded state and re-renders that message's section via `evaluateJavaScript` (or reloads the document — both are local). "Load images" is a per-message button rendered in HTML for the same reason.
- Threads are rendered from SQLite, never from the network; opening a thread = build one string + `loadHTMLString`. No height measurement anywhere.
- The single-message case is the same code path with N = 1.

Keep the embedded-with-measured-height approach only as a documented fallback (if the owner later wants native per-message cells): inject a `WKUserScript` at `.atDocumentEnd` with a `ResizeObserver` on `document.documentElement` that posts `scrollHeight` to `messageHandlers.mm`, debounce in Swift, and set `scrollView.isScrollEnabled = false` on the web view. `WKUserScript.init(source:injectionTime:forMainFrameOnly:)` [V].

---

## 5. Outgoing mail styling (default font / size / colour + HTML signature)

### 5.1 How Gmail and Apple Mail do it

- Gmail web "Default text style" (Settings → General) offers a curated font list (Sans Serif/Arial, Serif, Fixed width, Wide, Narrow, Comic Sans, Garamond, Georgia, Tahoma, Trebuchet, Verdana), sizes Small/Normal/Large/Huge, and a colour [S support.google.com snippets]. In the sent HTML each compose block becomes `<div class="gmail_default" style="font-family:verdana,sans-serif;font-size:small;color:#0b5394">…</div>` and the signature `<div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">…</div>` — UNVERIFIED exact markup (no fetchable sample this session; from memory of Gmail source). What is certain from the search results: Gmail's default size "small" renders at ≈13 px, default family is Arial/"Sans Serif" [S], and Gmail relies on **inline styles**, stripping `<style>` in some contexts [S].
- Apple Mail: default compose font Helvetica 12 pt on macOS; composed HTML uses `-webkit-text-size-adjust: auto`, `font-family: Helvetica` and `Apple-style-span`/`Apple-interchange-newline` spans (macOS), quoted text in `<blockquote type="cite">` [S — search snippets only; sample archive fetch was blocked]. iOS Mail has no user-facing default-font setting [S Apple Community threads].
- Both clients therefore apply the default **by inline style on block wrappers**, never via `<style>` or `<body>` attributes — because Outlook (Word engine) and Gmail web drop/override document-level styles.

### 5.2 Wrapper vs. per-paragraph

Use **one wrapper `<div>` with the full inline style, and one `<div>` per typed line inside it** (empty lines = `<div><br></div>`). Reasons: (1) inheritance of `font-family`, `font-size`, `color` through `div` children works in Gmail, Apple Mail, Outlook desktop and Outlook.com — the wrapper is what Gmail's `gmail_default` effectively is; (2) per-line `div`s avoid Outlook's `<p>` paragraph spacing; (3) when the recipient replies, their client quotes the wrapper and the style survives intact. Do **not** put the style on `<body>` (Gmail web strips `<body>` attributes) and do not use `<font>` (deprecated; `size` is not px).

Quoted original (reply-all / forward) goes **outside** the styled wrapper so the default colour/font is not applied to the other party's text.

### 5.3 Font stacks that render on Outlook/Gmail

Curated list (every entry is a "web-safe" family present on Windows, macOS, iOS; each ends in a generic family so no client picks Times by accident). `-apple-system`/`system-ui` are deliberately excluded from outgoing mail: Outlook Windows ignores unknown names and would fall to the next entry anyway [S courier.com / omnisend snippets].

| id | Display name | `font-family` value |
|---|---|---|
| `helvetica` | Helvetica (Apple Mail default) | `Helvetica, Arial, sans-serif` |
| `arial` | Arial (Gmail default) | `Arial, Helvetica, sans-serif` |
| `verdana` | Verdana | `Verdana, Geneva, sans-serif` |
| `tahoma` | Tahoma | `Tahoma, Geneva, sans-serif` |
| `trebuchet` | Trebuchet MS | `'Trebuchet MS', Helvetica, sans-serif` |
| `georgia` | Georgia | `Georgia, 'Times New Roman', serif` |
| `times` | Times New Roman | `'Times New Roman', Times, serif` |
| `courier` | Courier New | `'Courier New', Courier, monospace` |

Sizes: store **px** (Gmail semantics; Outlook converts px fine). Offer 12, 13, 14, 15, 16, 18. Colour: `#RRGGBB` lowercase hex, validated by regex `^#[0-9a-f]{6}$`.

### 5.4 User config representation

```swift
struct ComposeStyle: Codable, Equatable {
    enum Family: String, Codable, CaseIterable, Identifiable {
        case helvetica, arial, verdana, tahoma, trebuchet, georgia, times, courier
        var id: String { rawValue }
        var css: String {
            switch self {
            case .helvetica: "Helvetica, Arial, sans-serif"
            case .arial:     "Arial, Helvetica, sans-serif"
            case .verdana:   "Verdana, Geneva, sans-serif"
            case .tahoma:    "Tahoma, Geneva, sans-serif"
            case .trebuchet: "'Trebuchet MS', Helvetica, sans-serif"
            case .georgia:   "Georgia, 'Times New Roman', serif"
            case .times:     "'Times New Roman', Times, serif"
            case .courier:   "'Courier New', Courier, monospace"
            }
        }
        var displayName: String { … }
    }
    var family: Family = .helvetica
    var sizePx: Int = 14
    var colorHex: String = "#000000"
    var signatureHTML: String = ""            // raw HTML pasted by the owner; sanitized with the same Sanitizer, `card`-agnostic

    var inlineCSS: String { "font-family:\(family.css);font-size:\(sizePx)px;color:\(colorHex)" }
}
```
Persist in `UserDefaults` under one key as JSON (PLAN.md: "UserDefaults + Codable Preferences struct").

### 5.5 Serialising the outgoing HTML body

```swift
enum OutgoingHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    /// Plain text typed in UITextView -> styled HTML body (no <html>/<body>; the MIME builder wraps it).
    static func body(text: String, style: ComposeStyle, quotedHTML: String?, quoteHeader: String?) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "<div><br></div>" : "<div>\(escape(line))</div>"
        }.joined()
        var html = "<div class=\"minimail_default\" style=\"\(style.inlineCSS)\">\(lines)</div>"
        if !style.signatureHTML.isEmpty {
            html += "<div><br></div><div class=\"minimail_signature\" style=\"\(style.inlineCSS)\">\(style.signatureHTML)</div>"
        }
        if let q = quotedHTML {
            html += "<div><br></div><div class=\"minimail_quote\">"
            if let h = quoteHeader { html += "<div style=\"\(style.inlineCSS)\">\(escape(h))</div>" }   // "On <date>, <name> wrote:"
            html += "<blockquote type=\"cite\" style=\"margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex\">\(q)</blockquote></div>"
        }
        return html
    }
}
```
- The signature is wrapped in its own styled `div`, so an unstyled signature inherits the defaults while any inline styles inside the signature win (inner rules beat inherited ones). Sanitize `signatureHTML` once when saved (same `Sanitizer`, but keep `http(s)` `img src` and skip the `data-src` neutralization — you authored it). Inline images in the signature are out of scope for stage 1; link to hosted images.
- `quotedHTML` is the **sanitized** body of the original (from SQLite) with `data-src` restored to `src` for remote images (you are forwarding the sender's mail; do not embed your placeholder GIF) and `minimail-cid://…` rewritten back to `cid:` with the parts re-attached (forward) — MIME builder detail for the "Compose" research topic.
- Send as `multipart/alternative` with a `text/plain` part generated from the typed text + signature stripped of tags, and the HTML part `Content-Type: text/html; charset=utf-8`, `Content-Transfer-Encoding: quoted-printable` (standard practice; not part of this topic).
- Wrap the whole thing for the MIME part as `<html><head><meta charset="utf-8"></head><body>…</body></html>`; do **not** include a `color-scheme` meta in outgoing mail (it would opt Apple Mail recipients into partial inversion of your plain text — that is what the "with meta but no styles" warning in §3.1 is about).

---

## 6. Performance

1. **Pre-rendering cost.** The expensive part is the first WebContent process launch, not parsing an email. Create the pooled web view after the first inbox paint (`Task { @MainActor in … }` after `.task` of the list) and warm it with `loadHTMLString(template(empty), baseURL: nil)`; subsequent `loadHTMLString` calls of ~100 KB documents are tens of milliseconds (UNVERIFIED figure; measure with `os_signpost`). `suppressesIncrementalRendering = true` [V] makes the first paint the complete paint — no partial-layout flicker — and costs nothing for local content.
2. **Cache sanitized HTML** (PLAN.md rule): sanitizer runs in the sync engine on the body fetch (`format=full`), off the main actor, result stored in `message.body_html` with `has_remote_images`, `dark_strategy`, `sanitizer_version`. Thread open = SQLite read + string concat. Never store raw HTML; on a sanitizer bump re-fetch bodies lazily (`format=full` again) when `sanitizer_version < Sanitizer.version`.
3. **No re-layout on scroll.** With the web view as the scroller, nothing native is measured while scrolling. Inside the document avoid layout thrash: fixed `img` dimensions are kept from the sender's `width/height` attributes, placeholders are 1×1 so blocked images collapse instead of reserving space (Apple Mail behaviour), `table-layout` left to the sender.
4. **WKProcessPool sharing** is moot (deprecated iOS 15, "no longer has any effect") [V]. One reused instance = one process anyway.
5. **Memory.** WebContent memory is accounted outside the app; worst case is a blank web view, not a jetsam of minimail [V]. Still: exactly one WKWebView alive; on `UIApplication.didReceiveMemoryWarningNotification` and when leaving the thread screen load the empty template to drop the DOM. `WKWebsiteDataStore.nonPersistent()` keeps no disk cache to grow [V].
6. **Battery.** Nothing in the web view can create network traffic (rule list + CSP + no JS), no timers run (no JS), no video/audio (stripped). The only network work is the user's explicit "Load images" and `attachments.get` for inline `cid` parts, both through `URLSession` in the app with normal caching.
7. **Rule list compile** happens once per identifier and is persisted by the store [V]; `prepare()` runs at launch in the background and the web view is created after it finishes (or add the list to the live `userContentController` when ready).
8. **Avoid the white flash in dark mode**: `isOpaque = false` + `backgroundColor` set **before** the first load (forum 121139) [V], `underPageBackgroundColor` (iOS 15+) for overscroll [V], and `body { background: transparent }` in the template so the themed UIView colour shows through.

---

## 7. Open items / UNVERIFIED list (for the executor to confirm in code)

- `WKUserContentController.remove(_ contentRuleList:)` / `removeAllContentRuleLists()` names.
- Whether content rule lists see `data:`/custom-scheme loads (irrelevant with the `^https?://` patterns).
- Newer `resource-type` values (`ping`, `fetch`, `websocket`, `other`) and the exact `url-filter` regex subset (WebKit blog blocked).
- CSP `img-src minimail-cid:` accepted by WebKit for an app-registered scheme (fallback: omit the CSP meta, rely on rule list).
- SwiftSoup element API names used in the snippets (`select`, `attr`, `removeAttr`, `addClass`, `remove`) and `testValidProtocol` behaviour for relative `src`.
- Gmail's exact `gmail_default` / `gmail_signature` markup and Apple Mail's `Apple-style-span` markup (only needed for aesthetics; our own class names are fine).
- `overrideUserInterfaceStyle` propagating into `prefers-color-scheme` inside WKWebView; Dynamic Type re-layout without reload.
- Sizes: SwiftSoup binary impact; `loadHTMLString` latency.

## Sources (fetched this session unless marked blocked)

- Apple WebKit docs (JSON backing developer.apple.com): `WKWebpagePreferences.allowsContentJavaScript`, `WKPreferences.javaScriptEnabled` (deprecated), `WKContentRuleListStore`, `compileContentRuleList(forIdentifier:encodedContentRuleList:)`, `lookUpContentRuleList(forIdentifier:completionHandler:)`, `WKUserContentController.add(_:)`, `allowsLinkPreview`, `dataDetectorTypes`, `isTextInteractionEnabled`, `ignoresViewportScaleLimits`, `pageZoom`, `mediaType`, `preferredContentMode`, `defaultWebpagePreferences`, `underPageBackgroundColor`, `isInspectable`, `WKURLSchemeHandler`, `setURLSchemeHandler(_:forURLScheme:)`, `WKURLSchemeTask`, `loadHTMLString(_:baseURL:)`, `loadFileURL(_:allowingReadAccessTo:)`, `WKProcessPool` / `processPool` (deprecated iOS 15), `websiteDataStore`, `WKWebsiteDataStore.nonPersistent()`, `suppressesIncrementalRendering`, `WKUserScript.init(source:injectionTime:forMainFrameOnly:)`, `WKScriptMessageHandler`, `evaluateJavaScript(_:)`, `callAsyncJavaScript(_:arguments:in:in:completionHandler:)`, `webView(_:decidePolicyFor:decisionHandler:)` (action + response variants), `limitsNavigationsToAppBoundDomains` — all under `https://developer.apple.com/documentation/webkit/…`.
- `https://developer.apple.com/documentation/safariservices/creating-a-content-blocker` (rule JSON structure, action fields, evaluation order).
- WebKit source: `https://github.com/WebKit/WebKit/blob/main/Source/WebCore/contentextensions/ContentExtensionParser.cpp` (trigger keys, action types).
- WWDC20 10188 "Discover WKWebView enhancements": `https://developer.apple.com/videos/play/wwdc2020/10188/`.
- Apple forums: `https://developer.apple.com/forums/thread/21956` (memory accounting), `/thread/742739` (RBS log noise, FB13464160), `/thread/121139` (white flash), `/thread/816838` (content height), `/thread/723008` (text-size-adjust on iPad), `/thread/732778` (`trigger` vs `condition`).
- SwiftSoup: `https://github.com/scinfu/SwiftSoup` (tags page; raw `Package.swift`, `README.md`, `Sources/SwiftSoup.swift`, `Sources/Whitelist.swift`, `Sources/Cleaner.swift` on `master`).
- CSP3 spec source: `https://github.com/w3c/webappsec-csp/blob/main/index.bs`. HTML spec source: `https://github.com/whatwg/html/blob/main/source` (`meta name=color-scheme`).
- Gmail API discovery document (`gmail/v1`): `users.messages.attachments.get`, `MessagePartBody`, `MessagePart`, `messages.get` `format` enum.
- Dark mode: `https://github.com/hteumeuleu/email-bugs/issues/104`, `https://github.com/matthieuSolente/email-darkmode`; blocked but cited via snippets: `https://www.litmus.com/blog/the-ultimate-guide-to-dark-mode-for-email-marketers`, `https://www.emailonacid.com/blog/article/email-development/dark-mode-for-email/`, `https://mailchimp.com/help/design-emails-dark-mode/`, `https://mailtester.com/blog/gmail-app-dark-mode-color-changes/`, `https://www.mailmode.app/learn/gmail-dark-mode-email-rendering-guide`.
- Tracking pixels: `https://github.com/apparition47/MailTrackerBlocker/blob/main/Source/MTBBlockedMessage.m`, `https://github.com/EnriqueITE/PixelGuard`.
- Height measurement: `https://github.com/Asperi-Demo/4SwiftUI/blob/master/Answers/WKWebView_content_height_in_ScrollView.md`, `https://gist.github.com/pkuecuekyan/f70096218a6b969e0249427a7d324f91`.
- Blocked (not fetched): `https://webkit.org/blog/3476/content-blockers-first-look/`, `https://webkit.org/blog/8840/dark-mode-support-in-webkit/`, `https://developers.google.com/workspace/gmail/design/css`, `https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Content-Security-Policy`, `https://www.caniemail.com/…`.
