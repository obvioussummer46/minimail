# minimail — implementation plan

Read this first. It is the index and the task order for stage 1.

## 1. How to use this plan

Reading order:

1. This file.
2. `design/architecture.md` — why every decision is what it is. Start with §0 "Decisions at a glance" and §16 "Non-goals".
3. `spec/<module>.md` — the implementation contract for the module you are building. Each spec has the same 10 sections: purpose, files, public interface, behaviour, data, UI, tests, tasks, acceptance criteria, open questions.
4. `research/*.md` — verified platform and API facts. Specs cite them as `[gmail-api §7]`. Anything marked UNVERIFIED was not confirmable from an official source; the spec that uses it states a fallback.

Rules:

- **Specs are the contract.** Architecture is the rationale. If a spec contradicts the architecture, stop and flag it rather than guessing.
- **One commit per task**, message `T<module>.<n>: <title>`.
- **A task is done when its verification command passes**, not when the code looks right. Every task names its command.
- Do not widen a task. If a task needs a symbol that does not exist yet, its dependency task comes first in the order below.
- Facts marked UNVERIFIED must stay marked. Do not silently promote an assumption to a fact.

Build commands (defined by T01.1, see `spec/01-project-setup.md` §5):

| Command | What it does | Runs on |
|---|---|---|
| `make gen` | XcodeGen regenerates the project from `project.yml` | macOS |
| `make build` | Builds the app for the simulator | macOS |
| `make test-app` | Runs the app test target | macOS |
| `make test-one T=<target>/<class>` | Runs one test class | macOS |
| `make core-test` | `swift test` for the MailCore package | Linux or macOS |
| `make lint` / `make format` | SwiftLint / swift-format | either |
| `make fixtures-check` | Validates the fixture catalog | either |
| `make qa` | Everything above in order | macOS |

MailCore is a dependency-free local package, so `make core-test` runs on Linux in seconds. Modules 02, 03 and the pure parts of 06 are verifiable without a Mac.

## 2. Prerequisites the owner must do by hand

None of these can be scripted. The build fails closed with placeholder values, so start them early.

| # | Task | Where the value lands |
|---|---|---|
| 1 | Create a Google Cloud project **inside the example.com organization**; set the OAuth consent screen user type to **Internal** (no verification review, no 7-day token expiry) | — |
| 2 | Enable the Gmail API in that project | — |
| 3 | Create an **iOS** OAuth client for bundle id `com.minimail` | `GOOGLE_CLIENT_ID` and `REVERSED_CLIENT_ID` in `Config/Secrets.xcconfig` (git-ignored) |
| 4 | Workspace admin: mark the client Trusted, or enable "Trust internal, domain-owned apps" under Security → API controls. Without this, sign-in fails with `admin_policy_enforced` | — |
| 5 | Apple Developer account; register bundle id `com.minimail` | `DEVELOPMENT_TEAM` in `Config/Secrets.xcconfig` |
| 6 | A macOS machine or runner with Xcode 26.x for `make build` / `make test-app` | — |
| 7 | For TestFlight only (T14.9–T14.11): App Store Connect app record and an API key | `Config/appstore.env`, git-ignored |

The only scope requested is `https://www.googleapis.com/auth/gmail.modify`. It covers read, label changes, archive and send.

## 3. Task order

121 tasks across 14 modules. Modules are ordered by dependency; inside a module the tasks are strictly sequential. Full titles, files, definitions of done and verification commands live in each spec's §8.

### M1 — foundation and a read-only inbox

| Module | Tasks | Spec | Parallel with |
|---|---|---|---|
| 01 project setup | T01.1 – T01.9 | `spec/01-project-setup.md` | — (must be first) |
| 02 MailCore MIME | T2.1 – T2.9 | `spec/02-mailcore-mime.md` | 04 |
| 03 MailCore Gmail model | T03.1 – T03.9 | `spec/03-mailcore-gmail-model.md` | 04 |
| 04 auth | T04.1 – T04.8 | `spec/04-auth.md` | 02, 03 |
| 05 Gmail client | T05.1 – T05.6 | `spec/05-gmail-client.md` | 06 |
| 06 storage | T06.1 – T06.12 | `spec/06-storage.md` | 05 |

After M1 the app signs in, syncs nothing yet, and has a database and an API client with tests.

### M2 — sync, reading, labels

| Module | Tasks | Spec | Parallel with |
|---|---|---|---|
| 07 sync + outbox | T07.1 – T07.12 | `spec/07-sync-outbox.md` | 08 |
| 08 HTML rendering | T08.1 – T08.8 | `spec/08-html-rendering.md` | 07 |
| 09 inbox list | T09.1 – T09.9 | `spec/09-inbox-list.md` | — |
| 10 thread view | T10.1 – T10.8 | `spec/10-thread-view.md` | 12 |
| 12 labels | T12.1 – T12.6 | `spec/12-labels.md` | 10 |

After M2: Inbox, Today, Unread-only and label views; open a thread, read HTML safely, archive, mark read/unread, delta sync, optimistic actions with an outbox.

### M3 — writing

| Module | Tasks | Spec |
|---|---|---|
| 11 compose | T11.1 – T11.6 | `spec/11-compose.md` |

Reply-all and forward, with the quoted original, the HTML signature and the configured font and colour, sent through the outbox.

### M4 — settings, themes, QA, TestFlight

| Module | Tasks | Spec |
|---|---|---|
| 13 settings, theme, signature | T13.1 – T13.8 | `spec/13-settings-theme-signature.md` |
| 14 QA and release | T14.1 – T14.11 | `spec/14-qa.md` |

T14.1 – T14.4 (fixture catalog and loader) may be pulled forward to just after T01.9 if you prefer fixtures in place before the parsers.

## 4. Definition of done for stage 1

- `make qa` green: MailCore tests, app tests, lint, format, fixture check.
- Every module's §9 acceptance criteria met.
- The device checklist in `device-checklist.md` (written by T14.7) passes on a real iPhone with the work account.
- Cold start under 400 ms to the first painted list, measured with signposts on device.
- A TestFlight build installed and used for a day without a battery-usage entry beyond ordinary foreground use.

## 5. Known unverified facts

These came back unconfirmed from official sources; each spec states the fallback it takes.

| Fact | Fallback taken |
|---|---|
| Per-method Gmail quota units and per-user limits | Conservative budget; the request limiter backs off on 429 rather than predicting cost |
| "100 calls per batch" guidance | Batches capped at 25 |
| Whether `labels.list` returns colours | Colours fetched per label via `labels.get`; missing colour renders as the system accent |
| Whether `after:` accepts epoch seconds | "Today" is computed locally from `internalDate` in the device time zone, never server-side |
| Attachment id stability across fetches | Ids re-read on open; a stale id retries once with a fresh `messages.get` |
| Refresh-token expiry rules for Workspace | Any `invalid_grant` drops to the sign-in screen with a clear message |
| `WKContentRuleListStore.default()` inside the test host | Test-only store override |

## 6. Out of scope for stage 1

Composing a new message from scratch, search, multiple accounts, push notifications, snooze, a drafts UI, calendar, contacts, threading beyond Gmail's own `threadId`. See `design/architecture.md` §16.

## 7. Files

```
docs/plan/
  README.md                  this file
  design/architecture.md     final architecture (§0 decisions, §15 decision log, §16 non-goals)
  design/modules.md          module scopes
  design/candidate-*.md      three superseded design candidates, kept for rationale
  research/gmail-api.md      endpoints, params, history, batch, OAuth, quotas
  research/ios-platform.md   Xcode/Swift versions, AppAuth, GRDB, BGTaskScheduler, WebKit, SwiftUI
  research/mime-rfc.md       RFC 5322/2045/2047/2231 rules, byte-exact examples, reply-all vectors
  research/html-rendering.md sanitisation, WKWebView hardening, dark mode, outgoing styles
  research/tooling.md        XcodeGen, xcodebuild, CI, signing, TestFlight
  spec/01..14-*.md           implementation contracts
```
