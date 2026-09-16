# minimail — TestFlight runbook

How the owner ships a build to TestFlight. Everything here needs a Mac with Xcode 26.x and an Apple
Developer account; none of it runs in CI without the secrets below.

## One-time owner setup
1. **Apple Developer Program** membership (individual or org).
2. **Bundle id** `com.minimail` registered at developer.apple.com → Identifiers, with the Keychain Sharing
   capability (the app uses `$(AppIdentifierPrefix)com.minimail`, already in `project.yml`).
3. **App record** in App Store Connect (TestFlight) for `com.minimail`.
4. **Signing.** Automatic signing with your team in Xcode is simplest for the first archive. For CI, create a
   Distribution certificate + App Store provisioning profile and an **App Store Connect API key** (Keys tab):
   note the Key ID, Issuer ID, and download the `.p8` once.
5. Confirm `Config/Signing.xcconfig` points at your team (see `memory`: Bittel UG = GKP7686BZ3, personal =
   42436Y52QF) and `ExportOptions.plist` uses `method: app-store-connect`.

## Build numbering
- `MARKETING_VERSION` (e.g. `0.1.0`) is the user-facing version; bump it per release in `project.yml`.
- `CURRENT_PROJECT_VERSION` (build number) must strictly increase per upload. Bump it on every archive
  (`agvtool`/manual). App Store Connect rejects a duplicate build number.

## Archive + upload (local, path 1)
```
export ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer uuid>
make upload-testflight
```
`archive` fails fast when `ASC_KEY_ID` is unset or `Config/*.xcconfig` still holds `REPLACE` placeholders, so
a misconfigured machine stops before a 10-minute build. `ASC_KEY_PATH` defaults to
`~/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8`; set it explicitly if the key lives elsewhere.
`make bump-build` increments `CURRENT_PROJECT_VERSION` first — commit that when you want the number to be
reproducible from the repository.

## GitHub Actions (path 2)
`.github/workflows/release.yml`, `workflow_dispatch` only, on a `macos-26` runner. It fills the two config
files from secrets, writes the API key to `$RUNNER_TEMP/keys`, runs `fixtures-check` → `core-test` →
`test-app`, then `make upload-testflight`, and deletes the key in an `always()` step. The `bump` input
(default true) runs `make bump-build` on the runner; that change is never committed, so a dispatched build
takes the next number only for that run.

Six secrets, on the repository or on its `testflight` environment:

| Secret | Value |
|---|---|
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | issuer UUID from the same page |
| `ASC_KEY_P8` | the **whole `-----BEGIN PRIVATE KEY-----` text**, not base64 — the workflow writes it to a `.p8` verbatim |
| `APPLE_TEAM_ID` | 10-character team id; also substituted into `ExportOptions.plist` |
| `GOOGLE_CLIENT_ID` | iOS OAuth client id |
| `GOOGLE_REVERSED_CLIENT_ID` | its reversed form, the URL scheme |

None is ever echoed. Both paths produce the same artefact; the local one is the faster loop while signing is
still being sorted out.

## After upload
- The build appears in App Store Connect → TestFlight after processing (minutes to ~an hour).
- Add the required export-compliance answer (no non-exempt encryption → "No").
- Assign to the internal testing group; installs via the TestFlight app.

## Troubleshooting
- **"Provisioning profile doesn't match the entitlements' keychain-access-groups"** — the entitlement must be
  `$(AppIdentifierPrefix)com.minimail` (already fixed in `project.yml`); regenerate with `xcodegen generate`.
- **Duplicate build number** — bump `CURRENT_PROJECT_VERSION`.
- **Fallback (no paid account):** free provisioning installs directly from Xcode to a tethered device for the
  device checklist, but cannot use TestFlight.
