# Implementation notes

Running record of deviations from the specs and of things the specs left unverified. One section per module.

## Environment caveat for module 01

The container this code was written in has **no Swift toolchain** and the proxy blocks `download.swift.org`,
so nothing below has been compiled or run. Every task in module 01 is written but **unverified**. First thing
to do on a Mac:

```sh
make core-test     # MailCore + MailHTML, also works on Linux with a Swift 6.1 toolchain
make gen && make build
make test-app      # expects 42 passing tests
make lint
```

Expect to fix compile errors on the first pass. The likely spots are listed under "Risk list" below.

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

- T01.9 simulator smoke: needs a Mac with a simulator.
- Acceptance criteria 2, 3, 4, 5, 6, 8, 9: all need a Mac or GitHub Actions.

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

## Verification status (CI is the compiler)

`.github/workflows/ci.yml` gives this project a compiler without a Mac. The `core` job runs `swift test` for
the MailCore package on an Ubuntu runner in about 25 seconds; the `ios` job runs lint, the package tests and
the app tests on a macOS runner. Read failures with the GitHub Actions API rather than downloading the log
archive, which the sandbox proxy blocks.

**Green as of commit `2c454b7`:** the `core` job. 149 MailCore and MailHTML tests pass on Linux. That covers
all of modules 02 and 03 plus `ComposeStyle`.

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
