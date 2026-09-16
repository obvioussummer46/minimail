# minimail — test fixtures

Where the test data lives and how to regenerate it.

`CATALOG.txt` exists in both roots and `scripts/check-fixtures.py` enforces it (`make fixtures-check`, run by
`make qa` and by CI before the package tests). It describes the **11 fixtures that exist**, not the 65 spec 14
§5.1 anticipated: modules 02/03/05 kept their Gmail and MIME payloads inline in the test files (their D1
deviations, recorded in `docs/plan/IMPLEMENTATION-NOTES.md`), so the `gmail` and `mime` families are empty.
The script keeps both family names and their `EXPECTED_SIZES` entries, so those checks switch themselves on if
the payloads are ever moved to disk.

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

## What the check enforces
`scripts/check-fixtures.py --check-order`, exit 0 or 1, standard library only so it runs on Linux:

- every catalog entry exists on disk and every file on disk is in the catalog (both differences are printed);
- entries sit in a known family, sorted inside it, families in the declared order;
- `*.json` parses; every catalogued file with a text suffix decodes as UTF-8;
- `*.eml` matches its `.sha256` sidecar, uses CRLF throughout and carries no bare LF;
- `*.raw.txt` is one line of unpadded base64url; `gmail/batch.*.txt` is committed LF-only;
- the four `EXPECTED_SIZES` byte counts, when those files are present.

## Still to back-fill
Moving the inline Gmail/MIME payloads into `Fixtures/gmail/*.json` and `Fixtures/mime/*` (owned by 02/03)
needs only the new paths added to `CATALOG.txt`; the checker covers them already. `FixtureLoader` and
`FixtureCatalogTests` (spec T14.4) remain unwritten — the app test target reads no fixture files today, since
the smoke tests build their data in code with `TestDatabase.seedSmoke`.

## Device quota numbers
Not yet captured. Device-checklist item **D31** collects the per-method call counts from the in-app request
log after a day of real use; they belong here, and they are the placeholder spec 14 §5.9 left open.
