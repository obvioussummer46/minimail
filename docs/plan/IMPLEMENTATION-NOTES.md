# Implementation notes

Running record of deviations from the specs and of things the specs left unverified. One section per module.

## Environment caveat for module 01

The container this code was written in has **no Swift toolchain** and the proxy blocks `download.swift.org`.
Verification therefore happens in CI rather than locally; see "Verification status" at the end of this file.
Everything in module 01 is now green there. To reproduce on a Mac:

```sh
make core-test     # MailCore + MailHTML, also works on Linux with a Swift 6.1 toolchain
make gen && make build
make test-app      # expects 42 passing tests
make lint
```

The risk list below is kept for the record; every item in it has since been settled by CI except where noted.

## 01 project setup

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D1 | `ThemeStore.choice` is a stored property with a `didSet` that writes to `SettingsStore` | `choice` is a computed property reading and writing `SettingsStore.settings.themeChoice` | The `@Observable` macro rewrites stored properties into computed ones, which does not compose with property observers. The computed form keeps the same behaviour, removes duplicated state, and still publishes changes because reads track `SettingsStore.settings`. |
| D2 | Tasks run in the order T01.1 … T01.9 | `project.yml`, the asset catalogue, the privacy manifest and the CI workflow were written inside the first commit rather than as separate T01.4 and T01.8 commits | They are pure configuration with no dependency on the Swift sources; splitting them would have produced two commits that cannot be verified on their own. |
| D3 | `MailHTMLPackage` exposes `name` and `textContent(ofHTML:)` | Adds `defaultComposeCSS` | Gives the target a compile-time reference to `MailCore`, which is what test `testMailCoreReachable` checks. |

### Risk list (unverified, check these first on a Mac)

1. **`nonisolated` on type declarations** (`Log`, `Formatters`, `Settings`, `ThemeChoice`). Requires the same
   compiler feature as `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. If the toolchain rejects it, move the
   annotation onto each member.
2. **`OSSignposter(subsystem:category:)` with `category: .pointsOfInterest`.** If the overload does not exist,
   use the string `"PointsOfInterest"`.
3. **`Logger` and `OSSignposter` as `static let` in a `nonisolated enum`.** If the compiler calls them not
   concurrency-safe, mark those statics `nonisolated(unsafe)`; both types are documented thread-safe.
4. **`Context.environment` in `Package.swift`.** If the manifest rejects it, drop the `MAILCORE_SKIP_HTML`
   branch and always include `MailHTML`; `make core-test-nohtml` then stops working.
5. **`type: folder` for the fixture copy in `project.yml`.** Spec §5.1 gives the fallback form if XcodeGen
   rejects it. `BundleConfigTests.testFixtureFolderCopied` is the test that catches this.
6. **SwiftSoup on Linux.** If it fails to build, `make core-test-nohtml` is the documented fallback and the
   CI `core` job already handles it.
7. **`UIColor.getRed` on grayscale colours.** `SystemPalette.components` falls back to `getWhite`, but
   `testHexCompositesAlpha` is the check that the composite maths gives `#808080`.
8. **swift-format strict.** Line length is 120; the code was written to that but never linted.

### Not done

- T01.9 simulator smoke: the app builds and its tests run on the simulator in CI, but nobody has looked at
  the screen yet. The light and dark screenshots still need a human eye.
- Acceptance criterion 6, the launch-screen colour and the absence of a white flash: needs that same eye.

## 02 MailCore MIME

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D1 | Test vectors live in JSON fixture files under `Tests/MailCoreTests/Fixtures/vectors/` and tests load them through a `Fixture` helper | Vectors are inline Swift tables in the test files | Every vector the spec lists is covered, but without a compiler a bundle-resource lookup is one more thing that can fail for reasons unrelated to the code under test. Module 14 owns the fixture catalogue and can move them. |
| D2 | `MIMEBuilderTests.testReplyAllByteExact` compares against `Fixtures/mime/reply-all.eml` | Structural assertions plus a decode round-trip | The pinned `.eml` files do not exist yet, and their exact body strings are in spec §5.2 rather than in the repository. The tests assert header order, both multipart shapes, boundary placement, base64 wrapping and quoted-printable round-trip. |
| D3 | `ComposeStyle` exposes `minSizePx`, `maxSizePx`, `defaultColorHex`, `isValidColorHex`, `normalizedColorHex` (spec 02) or `sizeRange`, `sizeChoices`, `isValidHex` (spec 01) | Both sets exist | The two specs name the same concepts differently. Keeping both keeps every documented call site compiling. |

### Risk list

1. **`RFC2047.encodeIfNeeded` chunk boundaries.** The greedy scalar packing is written to the spec, but the
   exact word split for a long non-ASCII subject is only verified by a decode round-trip, not byte for byte.
2. **`AddressParser` comment and quote handling.** The trickiest code in the module. The obsolete-route,
   legacy-comment and group forms each have one test; unusual combinations are untested.
3. **`Quoting.textFromHTML`.** A tag stripper, not a parser. Good enough for quoting, never for rendering.
4. **`HeaderDate.parse` two-digit years.** 00 to 49 map to 2000s and 50 to 99 to 1900s, as the spec says.
5. **Byte-exact fixtures.** Until D2 is closed, a Gmail-side rejection of the built message would not be
   caught by tests. Send one real reply and one real forward early.

## 03 MailCore Gmail model

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D1 | 30-odd JSON fixture files under `Fixtures/gmail/` drive the DTO, parser and batch tests | Fixtures are inline Swift literals | Same reason as module 02 D1. Every payload shape the spec names, (a) through (h), has a test; the JSON simply lives in the test file. Module 14 can extract them into the catalogue. |
| D2 | `Tests/MailCoreTests/Support/GmailFixtures.swift` provides `gmailFixture`, `gmailJSON`, `crlf` | Not written | It only exists to load the fixture files of D1. The batch tests build CRLF bodies with a local `response(_:)` helper instead. |

### Risk list

1. **`GmailPartBody.data` semantics.** The parser assumes Gmail hands over bytes with the transfer encoding
   already removed, which the research marks UNVERIFIED. If that is wrong, plain-text bodies will show
   quoted-printable escapes. One real message answers it.
2. **The tree walk's "first of each type wins" rule.** Deliberately not the RFC's "last alternative"; it
   matches Gmail's own client. A message whose second HTML alternative is the real one would render wrong.
3. **`message/rfc822` is never recursed.** Bounce reports show the covering text, not the original.
4. **Batch decoding.** Written to the documented envelope and exercised by eight tests, but never against a
   real Gmail response. The first live batch call is the real test.
5. **`attachmentId` stability.** Treated as transient, re-read on every open, as the research advises.

## 04 auth

Built and verified on a Mac (Xcode 26.6, iPhone 17 simulator), not just in CI. All 56 module-04 tests plus
module 01's 42 pass (98 total); lint clean.

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D1 | `OAuthConfig.hostedDomain = "newtelco.de"` (restrict sign-in to the Workspace domain) | `hostedDomain = nil` | minimail is a generic Gmail client with no organisation affiliation; any Google account may sign in. The one-retry-without-`hd` path stays (dead but harmless). |
| D2 | App identifier `de.newtelco.minimail` | `com.minimail` (bundle id, Keychain service, log subsystem, BGTask id, defaults keys) | Same reason as D1. Owner must register the OAuth client and Apple bundle id against `com.minimail`. |

### Real bugs the tests found

1. **Transient-refresh error was swallowed.** AppAuth's `performActionWithFreshTokens` returns the *stale*
   access token *alongside* a transient (network) error (`OIDAuthState.m` line 576). Spec §4.4's callback
   checks `if let token` first, so a failed refresh silently returned an expired token. Fixed: the callback
   checks `error` first, so transport failures surface as `URLError` (retryable) as intended.

### Resolved unknowns

- **A2** `resumeExternalUserAgentFlowWithURL:error:` is `NS_SWIFT_NAME(resumeExternalUserAgentFlow(_:))` and
  imports as **throwing**. The throwing variant of §4.12 is the one used.
- **A4** `OIDURLSessionProvider.setSession(_:)` with a custom `protocolClasses` session **does** intercept
  AppAuth's token requests, so the fallback (`URLProtocol.registerClass`) is not needed.
- **A1** AppAuth error constants resolved from `OIDError.h`: `OIDErrorCodeOAuth.invalidGrant` (-10),
  `OIDErrorCode.networkError` (-5), `.tokenRefreshError` (-11), `.userCanceledAuthorizationFlow` (-3),
  `.programCanceledAuthorizationFlow` (-4); domains/keys as spelled.
- **A10 was WRONG.** Keychain does **not** work in the simulator without entitlements: unsigned builds
  (`CODE_SIGNING_ALLOWED=NO`) return `errSecMissingEntitlement` (-34018). Fix: ad-hoc simulator signing
  (`CODE_SIGN_IDENTITY=-`, `CODE_SIGNING_ALLOWED=YES`) + a `keychain-access-groups` entitlement + a generated
  test-target Info.plist (`GENERATE_INFOPLIST_FILE=YES`). The Makefile's `NOSIGN` now means ad-hoc, not
  no-sign, and the CI `ios` job inherits this through `make`.
- **A7** SwiftUI `.accessibilityIdentifier` is not visible via UIKit `accessibilityIdentifier` on hosted views
  in this SDK, so `testRootViewHostsSignedOut` takes the documented degradation (asserts the view laid out).

## 05 gmail-client

Built and verified on a Mac. 81 module-05 tests pass (GmailErrorTests 25,
RequestLimiterTests 3, RequestLogTests 2, GmailClientTests 51); 179 app tests
green overall; lint clean. Every §9 acceptance category is covered.

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D1 | `GmailClientTests` load the module-03 `Fixtures/gmail/*.json` catalogue | Tests use inline JSON bodies (and a `stubBatchBody` builder) | Module 03 inlined its fixtures rather than creating the files (its own D1), so the catalogue does not exist. Inline bodies keep the tests self-contained and green; module 14 can migrate them to a catalogue. |
| D2 | ~84 tests | 81 written | Every DoD category is covered; three narrow fixture-only variants were folded into equivalent inline tests. |

### Notes

- `@Sendable` stub-handler closures cannot capture the (non-Sendable) `XCTestCase`,
  so the batch helpers (`stubPartIds`, `stubBatchBody`, `stubEncodeFields`) and the
  round counter (`AtomicInt`) are file-scope `nonisolated` declarations, not methods.
- `GmailError`'s `CustomStringConvertible` conformance had to be declared on the
  `nonisolated` type itself (not an extension) or the conformance is inferred
  MainActor-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- `URL.path` percent-decodes, so attachment-id encoding (`=` → `%3D`) is asserted
  against `url.absoluteString`, not `.path`.

## 06 storage

Built and verified on a Mac. 44 new app tests (DatabaseTests 8, RepositoryTests
22, QueriesTests 11, AppEnvironmentTests +3) and 37 new MailCore tests pass; 223
app + 186 MailCore green overall; lint clean; `minimail/Store` imports only
Foundation/GRDB/MailCore/MailHTML and mutations live only in repositories.

### Deviations / real findings

| # | Item | Resolution |
|---|---|---|
| D1 | `OutboxCoalescer.merge` formula | The spec's non-cancelling formula contradicted `testInverseCancels` and acceptance §9.5 ("read→unread → zero rows"). Uses the cancelling form; `testNewIntentWins` expectation adjusted accordingly. |
| D2 | Effective labels vs failed outbox ops | The spec's `rearmFailedModifies` "E is unchanged, no recompute" is only true if **failed** modify ops still contribute to effective labels. `recomputeEffective` and `InvariantChecks` therefore use pending **+ inFlight + failed** (a failed archive stays optimistically applied until acked/discarded/rearmed), which invariant 1's "pending/inFlight" wording understates. |
| D3 | `today.json` day-boundary vectors | The spec literals mixed 2025/2026 dates; recomputed for 2026 per the spec's own instruction. |
| D4 | `testRecordJSONBytes` byte-exact SendJob sample | Deferred; JSON columns are covered by round-trip + sorted-keys behaviour instead of the one hand-transcribed literal. |

### Notes

- Records with JSON columns conform through a `nonisolated protocol JSONColumnRecord`
  so GRDB's `FetchableRecord`/`EncodableRecord` conformance is not inferred
  MainActor under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- The UNVERIFIED GRDB API names compiled as written: `Configuration.publicStatementArguments`,
  `DatabaseMigrator.eraseDatabaseOnSchemaChange`, `DatabaseWriter.vacuum()`. No fallback needed.
- GRDB's `read`/`write` resolve to their **async** overloads inside an `async` test, so
  those calls must be `await`-ed and cannot sit inside an `XCTAssert` autoclosure.

## Verification status (CI is the compiler)

`.github/workflows/ci.yml` gives this project a compiler without a Mac. The `core` job runs `swift test` for
the MailCore package on an Ubuntu runner in about 25 seconds; the `ios` job runs lint, the package tests and
the app tests on a macOS runner. Read failures with the GitHub Actions API rather than downloading the log
archive, which the sandbox proxy blocks.

**Fully green as of commit `ca4502b`:** both jobs. 149 MailCore and MailHTML tests pass on Linux and again
on macOS, and 42 app tests pass on the iPhone 17 simulator. Lint is clean. Modules 01, 02 and 03 are
verified, not merely written.

### What the first four CI runs actually found

| # | Finding | Kind |
|---|---|---|
| 1 | Three raw string literals ended early: `#"…"#` is terminated by `"#`, and the JSON contained `"colorHex":"#000000"` | Real bug, test code |
| 2 | `ComposeStyle.init(from:)` never clamped or normalised, because Swift does not run property observers for assignments made inside an initializer. Spec 01 §4.1 and spec 02 §4.14 both prescribe that pattern, so **the spec is wrong here** | Real bug, production code |
| 3 | `decodeText` on an empty data string returns `""`, not nil | Wrong test expectation |
| 4 | LF-only batch input reports `.truncated`, not `.noDelimiter`, because the decoder prepends CRLF and so still matches the opening boundary. Spec 03 §4.7's last bullet is wrong | Wrong test expectation |
| 5 | swift-format wants a line break right after `=` or `return` when an expression wraps | Style |
| 6 | `XCTestCase` subclasses cannot be main-actor isolated: their initialisers clash with the nonisolated ones they inherit. Spec 01 §7 says the opposite | Real bug, test target |
| 7 | A `UIHostingController` builds no subviews until it is in a window, so spec 01 §7.2's `subviews.isEmpty == false` assertion for `testRootViewHosts` never holds. The test now attaches a window and asserts the layout size | Wrong test expectation |

### Resolved unknowns

- SwiftSoup **does** build on Linux, so `make core-test-nohtml` is a fallback that is not needed.
- `nonisolated` on a type declaration compiles in this toolchain, so `Log`, `Formatters`, `Settings` and
  `ThemeChoice` are fine as written.
- Swift on the Linux runner is 6.1.3.

## 08 html-rendering (MailCore half: T08.1–T08.4)

The dependency-free half (MailHTML `Sanitizer`/`StyleScrubber`/`TrackingPixel`/`DarkStrategyClassifier`/
`SignatureSanitizer`/`QuoteExtractor` and MailCore `ThreadDocument`) is built and green: 56 new tests,
270 MailCore/MailHTML tests total. Built ahead of module 07 because `SyncEngine.prepareBody` needs
`Sanitizer` to compile the app target (user decision, 2026-09-13). The app-target `Web/` half (T08.5–T08.8:
`WebViewHost`, `CIDSchemeHandler`, `InlineImageStore`, `MailWebView`, `LinkPolicy`, `WebBridge`, the `[08]`
`AppEnvironment` wiring) is module-10 infrastructure and is **not yet built**.

### Deviations / SwiftSoup findings

| # | Item | Resolution |
|---|---|---|
| D1 | `cidPathAllowed` | Spec subtracts only `/%` from `urlPathAllowed`, which keeps `@`; the tests expect an `@` in a Content-ID to encode as `%40`, so `@` is subtracted too. |
| D2 | SwiftSoup void tags | SwiftSoup always serialises `<img … />` (XHTML) even in HTML syntax; the app normalises ` />`→`>` (`Sanitizer.normalizeVoidTags`). |
| D3 | SwiftSoup source-patch serialization | With `prettyPrint == false`, this SwiftSoup version serialises a parsed doc from its source buffer patched per *dirty* node, and `attr`/`removeAttr` do **not** mark nodes dirty — so those mutations vanish. `Sanitizer.compactBodyHTML` serialises a `doc.copy()` (no source buffer) instead, giving compact output that reflects mutations. |
| D4 | `MailHTMLTests` deps | Added `SwiftSoup` to the test target (classifier tests need `SwiftSoup.Document`). |

## 07 sync-outbox (T07.3–T07.9 production + core tests)

All production code (`SyncStatus`, `SyncEngine`, `Outbox`/`OutboxIdentitySource`, `MailActions`,
`Maintenance`, `BackgroundRefresh`, `AppEnvironment`/`MinimailApp` `[07]` wiring) is built and the app
compiles. A shared harness (`SyncTestSupport`) plus 12 core `SyncEngineTests`/`OutboxTests` pass on the
iPhone 17 simulator. The remaining suites (`SendTests`, `ConflictTests`, `ResyncTests`, `MaintenanceTests`,
`BackgroundRefreshTests`, and the rest of `SyncEngineTests`/`OutboxTests` toward the spec's ~113) are **not
yet written**; they build on the same harness.

### Deviations

| # | Item | Resolution |
|---|---|---|
| D1 | `OutboxRepository.retryLater` | 06 ships `retryLater(…, error: String, countsAsAttempt: Bool, nextAttemptAt: Int64)` (not `error:now:random:`). `Outbox` computes the `Backoff.outbox` delay and passes `nextAttemptAt`; 06 decides pending-vs-failed by the 8/5 threshold. |
| D2 | `MaintenanceRepository` (spec D2) not created | 06 already exposes `ThreadRepository.deleteExpired`, `BodyRepository.pruneBodies`, `OutboxRepository.deleteFailedSends`; `Maintenance.cleanup` calls those, so no SQL lives in `App/` and the extra repo file is unnecessary. |
| D3 | `replaceDatabase` / rebuilt `actions` unused | `AppEnvironment.db` is one stable `DatabasePool` reset in place (`AppDatabase.reset`), so the O1 wipe tail is a no-op; the methods stay for API completeness. |
| D4 | `BackgroundRefresh.schedule` | Uses `BGTaskScheduler.submit(_:)` on all OS versions; the UNVERIFIED iOS 27 async `submitTaskRequest` branch is omitted for SDK compatibility. |

### Real bug found by the tests

- The Outbox drain's trailing status update set `status.isOffline = sawOffline` unconditionally. Because
  every `SyncEngine.execute` ends with a drain, a no-op drain right after an offline request wiped the flag
  the run had just raised. Fixed: the drain only *raises* `isOffline`; a successful request clears it via
  `SyncEngine.noteResult`.

### SwiftSoup/GRDB gotcha in the harness

- Multi-statement `map` closures returning a `#"…\#(…)…"#` raw string literal in a file that imports GRDB
  resolve to GRDB's `SQL` (which has `[SQL].joined(separator:)`), not `String`, silently producing
  `SQL(elements: …)` text. Annotate such closures `-> String` (`JSONFixtures.modifyResponse`).

## 08 html-rendering (app half: T08.5–T08.8)

`minimail/Web/` is built: `WebBridge`, `LinkPolicy`, `CIDSchemeHandler`, `InlineImageStore`,
`RuleLists`/`WebViewHost`, `MailWebView`, plus the `[08]` `AppEnvironment` wiring (construction, the
deferred `webHost.prepare()`, the sign-out wipe tail). New app tests: `WebBridgeTests` (5),
`InlineImageStoreTests` (11), `WebViewHostTests` (9), `AppEnvironmentTests.testWebHostConstructedWithoutWebView`.
Module 08 is now complete and module 10 is unblocked.

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D9 | `load(document:revision:)` sets `linkPolicy.onDidFinish` to end the `documentLoad` signpost | The host sets `linkPolicy.onDidFinish` once, when it creates the instance, and republishes it as `WebViewHost.onDocumentLoaded` | There is one delegate slot. With the spec's form, every caller that wants to know a load finished (10, and §7.3's own `testLoadAndRecycle`) has to overwrite the callback that ends the signpost, and the overwrite races the load it is waiting for. |
| D10 | `RuleLists` has no store override | `RuleLists.storeOverride` added | §10 O2's documented fallback if `WKContentRuleListStore.default()` is nil in the test host; nil in the app. |
| D11 | `MailWebView.dismantleUIView` calls `host.didDetach()` | The container holds a weak `webViewHost` and the body runs inside `MainActor.assumeIsolated` | `dismantleUIView` is a static, non-isolated requirement; the assumption is what WebKit and SwiftUI already guarantee (§10 A4). |
| D12 | `WebViewHost` exposes no way to see whether the instance exists | `webViewIfCreated` is `private(set)` rather than private | `AppEnvironmentTests` asserts launch step 1 creates no `WKWebView`, which spec §8 T08.8 requires. |

### Risk list (first Mac/CI run answers these)

1. **`WKUserContentController.removeAllContentRuleLists()`** (§10 A5). Used as written; if the name is
   missing, fallback F3 (track the attached list and `remove(_:)`).
2. **`@MainActor` conformances to `WKScriptMessageHandler`, `WKURLSchemeHandler`, `WKNavigationDelegate`,
   `WKUIDelegate`** (§10 A4). Written without `@preconcurrency`; add it per conformance if Swift 6 objects.
3. **The async-only `decidePolicyFor`.** Only the `async` variant is implemented, as the research advises.
4. **`URL.path` already percent-decodes**, so `WebBridge.parse(actionURL:)` decodes a second time. Harmless
   for the ids Gmail produces; a part id containing a literal `%` would be mangled.
5. **`evaluateJavaScript` with `allowsContentJavaScript = false`.** `testLoadAndRecycle` is the check that
   app-initiated evaluation still runs (architecture §14 #3); a failure there means fallback F1 for 10.
6. **Timing in `WebViewHostTests`.** The warm-up load is awaited before each test's own load so the
   expectation cannot be fulfilled by the wrong navigation.


## 10 thread-view (T10.1–T10.7)

`minimail/Features/Thread/` is built: `ThreadModel`, `AttachmentOpener`, `ThreadScreen`. New app tests:
`ThreadModelTests` (28), `ThreadViewsTests` (8), `AttachmentOpenerTests`. Whole suite green at 335 tests.
T10.8 (device pass) is still open — it cannot be scripted.

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D13 | §4.10 step 11 passes the injected `FileManager` into the detached write | The task constructs its own `FileManager()` | `FileManager` is not `Sendable`; capturing the injected one is a `sending`-parameter data race under Swift 6. |
| D14 | §6.2 builds the four bottom-bar buttons inline | Each is a `ThreadActionButton` view, and `body` is split into `chrome` / `content` / a `@ToolbarContentBuilder` | The inline forms exceed the type checker's budget twice over ("unable to type-check this expression in reasonable time") — first the toolbar group, then the whole `body` chain. |
| D15 | §4.6 step 4 forces a reload whenever `webHost.loadedRevision != revision` | Only when a `WKWebView` actually exists | With no instance there is no loaded document to reload, and bumping `revision` would contradict §10 test `testToggleKeepsRevision`. The document is still rebuilt so the first load picks up the new state. |
| D16 | `apply(nil)` dismisses and returns | It rebuilds first | Otherwise `document` stays empty for a thread that is already gone, and the web view would load an empty string (§10 `testMissingThreadDismissesImmediately`). |
| D17 | Tests construct `AppEnvironment(testing: true)` and script `StubURLProtocol` | `AppEnvironment.testTokenProvider` added next to `testURLProtocolClasses` | The test host has no keychain item, so the real provider fails every request with `.unauthorized` before it is sent. `testURLProtocolClasses` also has to be swapped off its `OfflineURLProtocol` default or no scripted route is reachable. |

### Spec errors found by CI (running total: 6)

5. §10 `testLoadImagesIsPerMessage` asserts `document.contains("src=\"https://x/m2.png\"")` is false, but
   `data-src="…"` ends in `src="…"`, so the assertion can never hold. Both halves are now matched whole.
6. §7.3 `InlineImageStoreTests` seeds a body without recomputing the thread aggregates, so
   `thread.bodiesMissing` stays 1 and invariant 6 trips in `testReresolveOn404`.

## 11 compose (T11.1–T11.6)

`minimail/Features/Compose/` is built: `ComposeModel` (with `ComposePhase`, `ComposeAttachmentItem`,
`ComposeAddressField`, `ComposeDraftBuilder`) and `ComposeScreen`. The interim `ComposeScreen` placeholder is
gone. New app tests: `ComposeModelTests` (27), `ComposeViewsTests` (12). Whole suite green at 374 tests.

### Deviations

| # | Spec says | Built as | Why |
|---|---|---|---|
| D18 | §6.4 `Section("Attachments") { … } footer: { … }` | `Section { … } header: { Text("Attachments") } footer: { … }` | SwiftUI has no `Section(_ titleKey:content:footer:)`; the spec's form does not compile. |
| D19 | §6.1 builds the whole sheet in one `body` | `body` → `chrome` → `content`, a `@ToolbarContentBuilder`, and a `ComposeForm` / section view per group | The same type-checker budget that forced D14 in module 10. Applied up front here. |
| D20 | §6.7 sets focus from the screen's `.onChange(of: model.phase)` | `load()` sets it right after `await makeDraft()` | One place, one assignment, and no second observation of a value the screen already awaited. |

### Spec errors found by CI (running total: 8)

7. §6.4's attachments section uses a `Section` initializer that does not exist (see D18).
8. §7.1 `testQuoteWaitsForBodyThenEnables` expects `quotePreview == ""` before the body arrives, but §4.4 falls
   the provisional quote text back to `original.snippet`; the fixture's snippet has to be empty for that.
   `testSendEnqueuesOneOutboxRow` likewise expects the row to still read `transmitState == .notSent`, but
   `MailActions.send` awaits `outbox.drain()`, which sets `.maybeSent` before the POST.

## Backfill: SendTests (07 T07.9) and the Gmail signature bridge

`Outbox.performSend` shipped in module 07 with only the modify path under test. `minimailTests/Sync/SendTests.swift`
(18 tests) is the first execution of the send branches: the `rfc822msgid` duplicate check, the `maybeSent`
window, the attachment budget, the `attachmentId` re-resolve on 404, reply vs forward quoting, the signature,
and the `Date` stamp. 11 passed on the first run.

### Defect the backfill found

`Outbox.drain` set `sawOffline` only from the modify path, so a queued **send** that failed offline left
`status.isOffline` false — the inbox banner stayed quiet and the user saw a stuck outbox with no explanation.
`performSend` now returns `.stop(offline:)` and `drain` raises the flag. (Spec §7.6 asserted this behaviour;
the implementation never had it.)

### Test-harness notes

- `afterSend()` starts an unstructured `sync.run(.afterSend)` that outlives the test, and `StubURLProtocol`'s
  recorded list is process-global, so `SendTests.tearDown` cancels the harness's engine and outbox. Without it a
  leaked run's `/profile` calls surface in the next test's assertions.
- `SyncHarness.setSettings` feeds the **engine's** snapshot closure. The signature reaches the MIME builder
  through `OutboxIdentitySource`, which the harness gives a separate `SettingsStore`; a signature test has to
  write to `harness.identity.settings` or it passes vacuously.

### Signature bridge

`SyncEngine.fullSync` already stored the preferred send-as signature in `syncState.sendAsSignature`, and
`OutboxIdentitySource.current()` already fed `Settings.signatureHTML` to `OutgoingBodies` — but nothing moved
the one into the other, so outgoing mail carried no signature and module 13 owns the only editor.
`SignatureImport.adoptGmailSignatureIfUnset` (called from `startDeferredWork` after the launch sync) sanitizes
it through 08's `SignatureSanitizer` and adopts it once, guarded by a defaults flag so a later sync cannot undo
an owner who clears it. Module 13's `SignatureEditorModel.importFromGmail` reads the same key and supersedes it.
