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

## Archive + upload (local)
```
xcodegen generate
xcodebuild -project minimail.xcodeproj -scheme minimail -configuration Release \
  -destination 'generic/platform=iOS' -archivePath .build/minimail.xcarchive archive
xcodebuild -exportArchive -archivePath .build/minimail.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath .build/export
xcrun altool --upload-app -f .build/export/minimail.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```
(`--apiKey` finds the `.p8` in `~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8` or `./private_keys`.)

## CI (deferred)
A manual `workflow_dispatch` GitHub Action (`macos-26` runner) can run the same steps with the API key stored
as repository secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (base64). Not wired up yet — add
`.github/workflows/release.yml` when the account and secrets exist.

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
