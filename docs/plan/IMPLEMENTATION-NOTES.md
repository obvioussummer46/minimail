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
