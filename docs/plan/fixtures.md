# minimail — test fixtures

Where the test data lives and how to regenerate it. Spec 14 §4.2 envisioned a single on-disk catalog
(`CATALOG.txt` per package test target) checked by `scripts/check-fixtures.py`. **That catalog is deferred**:
modules 02/03/05 chose to keep most fixtures inline in the test files (their D1 deviations, recorded in
`docs/plan/IMPLEMENTATION-NOTES.md`), so there is no 65-file corpus to catalog yet. This doc records the
fixtures that *do* exist on disk and how each family is produced.

## On disk today
| Path | Family | Notes |
|---|---|---|
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/smoke.json` | vectors | end-to-end smoke vector (module 01) |
| `Packages/MailCore/Tests/MailCoreTests/Fixtures/vectors/today.json` | vectors | day-boundary vector (module 06) |
| `Packages/MailCore/Tests/MailHTMLTests/Fixtures/html/*.html` (9 files) | html | sanitizer/render fixtures (module 08): `plain-mail`, `newsletter`, `signature`, `dark-native`, `inline-cid`, `tracking-pixels`, `malformed`, `xss-samples`, `smoke` |

Everything else (Gmail DTO/parser payloads, MIME wire vectors, batch bodies) is **inline** in the owning test
files (`MailCoreTests`, `GmailModelTests`, `MIMEBuilderTests`, `EncodingTests`, `HeadersTests`) and in module
07's `JSONFixtures` helper, where ids must line up with a seed.

## Loading
- **Package tests** (`swift test`) load on-disk fixtures via `Bundle.module` (`MailHTMLTests` `HTMLFixtures`,
  `MailCoreTests` `Fixture`).
- **App tests** (`minimailTests`) that need the same bytes read them through the `project.yml` folder copy; the
  smoke tests instead build their data in code via `TestDatabase.seedSmoke` (no fixture files needed).

## Regenerating
- **html/**: hand-authored minimal documents; edit in place. Keep them small and deterministic (no timestamps).
- **vectors/*.json**: hand-authored; `today.json` encodes the day-boundary cases for a fixed clock.
- **inline Gmail/MIME**: edit the literal in the owning test. If a payload is reused across tests, prefer moving
  it into a shared helper (module 03 `GmailFixtures`, 07 `JSONFixtures`) rather than duplicating.

## If/when the catalog is revived
Back-fill the inline Gmail/MIME payloads into `Fixtures/gmail/*.json` and `Fixtures/mime/*` (owned by 02/03),
then add `CATALOG.txt` (one path per line), `scripts/check-fixtures.py` (catalog↔disk, JSON parse, sha256,
CRLF discipline), `minimailTests/FixtureCatalogTests.swift`, and re-enable `fixtures-check` in `make qa` and CI.
