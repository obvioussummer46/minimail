# Working on minimail (read this, not the old plan)

Minimal, native Gmail client for iPhone. SwiftUI, iOS 17+, Swift 6 strict concurrency.
The app is **built and working**. Work here is small, prompt-scoped improvements.

## Status: the stage-1 plan is finished and archived

`docs/plan/` is the original 121-task, ~28k-line plan. Every stage-1 feature shipped. It is kept as a
historical record only.

- **Do not read `docs/plan/` at the start of a session.** Open a single file from it only when the user
  asks why something was designed a certain way.
- Do not audit, resume, verify, re-plan or "complete" that plan. There is nothing left to complete.
- Do not run large test campaigns or spawn parallel agents to check the plan. One agent, one change.
- Do not write to `docs/plan/IMPLEMENTATION-NOTES.md`. The commit message is the record.

## How to do a change

1. Read only the files the change touches. `PLAN.md` and this file are enough context.
2. Make the change. Keep it inside what the prompt asked for.
3. Verify with the cheapest command that proves it (below). Report the real result.
4. One commit per change, imperative message, e.g. `Inbox: keep scroll position after refresh`.

## Verification commands (cheapest first)

| Command | Runs | Time | Use when |
|---|---|---|---|
| `make core-test` | MailCore package tests (`swift test`) | seconds | anything in `Packages/MailCore` |
| `make lint` | swift-format strict + import rules | seconds | every change |
| `make build` | simulator build of the app | ~1-3 min | any change under `minimail/` |
| `make test-one T=minimailTests/<Class>` | one app test class on the simulator | ~2-4 min | the test class your change touches |
| `make test-app` | all app tests on the simulator | ~5-10 min | **only** before merging to `main` or when asked |
| `make fixtures-check` | fixture catalog (python, no toolchain) | seconds | after adding/removing test fixtures |

`make qa` = `core-test fixtures-check lint test-app`. Run it only before a merge to `main` or a release, never
"just to check". Simulator: `SIM_DEST='platform=iOS Simulator,name=iPhone 17'` (override with `make ... SIM_DEST=...`).
Never run xcodebuild in the background and move on; run it in the foreground and wait for the result.

## Branches and merging

- `main` is the integration branch. CI (`.github/workflows/ci.yml`) runs on every push to `main` and every PR.
- Feature work goes on short-lived branches (`claude/<topic>-<id>`), merged into `main` when
  `make build` and `make test-app` are green, then the branch is deleted.
- To merge a branch: `git merge --no-ff <branch>`, resolve conflicts, `make test-app`, push `main`.
- A branch with 0 commits ahead of `main` (`git rev-list --count main..<branch>` prints 0) is already
  merged: delete it, do not re-merge or re-review it.

## Deploying (TestFlight)

- From a Mac: `make bump-build && make upload-testflight` (needs `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_PATH`, and `DEVELOPMENT_TEAM` in `Config/Secrets.xcconfig`).
- From GitHub: run the `release` workflow (`.github/workflows/release.yml`, manual dispatch); it needs the
  six secrets listed in `docs/plan/testflight-runbook.md`.
- Owner-only prerequisites (Google Cloud OAuth client, Apple team, secrets) are listed in `PLAN.md`.

## Where things live

| Area | Path |
|---|---|
| App entry, environment | `minimail/App/` |
| Screens (Inbox, Thread, Compose, Labels, Settings, SignIn) | `minimail/Features/<Screen>/` |
| Sync engine, outbox | `minimail/Sync/` |
| GRDB database, records | `minimail/Store/` |
| Gmail API client, auth | `minimail/Gmail/`, `minimail/Auth/` |
| HTML rendering, WKWebView host | `minimail/Web/` |
| Theme system | `minimail/Theme/` |
| Pure logic, no Apple frameworks (MIME, Gmail DTOs, sanitiser) | `Packages/MailCore/` |
| App tests / package tests | `minimailTests/`, `Packages/MailCore/Tests/` |
| Project definition (XcodeGen) | `project.yml` → `make gen` |

## Rules that still hold

- Three dependencies only: AppAuth, GRDB, SwiftSoup (inside MailCore). No new packages.
- `MailCore` must not import UIKit, SwiftUI, GRDB, AppAuth, WebKit or Security (`make lint` enforces it).
- No timers, polling, sockets or prefetching. Local-first: the UI never waits on the network.
- Colours come from the theme, never hard-coded (`make lint` enforces the common cases).
- OAuth scope stays `gmail.modify` only.
