# minimail

Minimal, native, fast Gmail client for iPhone. Work account: Google Workspace.

**Status: stage 1 is complete. The app builds, is unit-tested and works.** Current work is small, gradual
improvements driven by individual prompts. Agents: read [`AGENTS.md`](AGENTS.md) for how to work here.

The original 121-task implementation plan (~28k lines) is archived under `docs/plan/` for reference only.
Nothing in it is pending. Do not resume it.

## What is built
- [x] Inbox with pull to refresh, Today view, Unread-only view
- [x] Gmail labels with counts
- [x] Open thread, read HTML safely (sanitised, one pooled WKWebView, JS off, remote images off)
- [x] Mark read / unread, archive, archive-and-read in one swipe
- [x] Reply all, forward with attachments, through an optimistic outbox
- [x] HTML signature (imported from Gmail, editable), default font and colour for outgoing mail
- [x] Dark mode with a theme system
- [x] Plain-text reading mode (Settings toggle, off by default)
- [x] Three-dot mark: app icon and mailbox switcher
- [x] `make qa` gate, CI on Linux + macOS, TestFlight release workflow

None of it has had a full pass on a real device yet: `docs/plan/device-checklist.md` is the list to walk
through once, on a phone with the work account.

## Next session (the one remaining housekeeping job)
- [ ] Merge branch `claude/xcode-plan-performance-k4746a` into `main` (it is `main` + the last unmerged
      feature branch + these docs; it merges clean)
- [ ] `make build && make test-app` on `main`
- [ ] Delete the remote branches that are already in `main` (all `claude/*` branches except the one above
      show 0 commits ahead of `main`)

## Owner to-do (manual, cannot be scripted)
- [ ] Google Cloud project, OAuth consent type **Internal**, Gmail API enabled
- [ ] iOS OAuth client for bundle id `com.minimail` → `Config/Secrets.xcconfig`
- [ ] Workspace admin: trust the client (else sign-in fails with `admin_policy_enforced`)
- [ ] Apple Developer team, bundle id registered → `DEVELOPMENT_TEAM` in `Config/Secrets.xcconfig`
- [ ] For TestFlight: App Store Connect API key, secrets per `docs/plan/testflight-runbook.md`

## Stack
| Area | Choice |
|---|---|
| UI | SwiftUI, iOS 17 floor, Swift 6 strict concurrency |
| Auth | AppAuth-iOS 3.0.0, PKCE, tokens in Keychain |
| API | Gmail REST v1 over URLSession, scope `gmail.modify` only |
| Sync | `history.list` delta sync, optimistic actions through an outbox |
| Storage | GRDB 7.11.1 (SQLite, WAL) |
| Email HTML | SwiftSoup sanitiser in `MailHTML`, one pooled WKWebView |
| Core logic | `MailCore` local package, zero Apple-framework imports, tests run on Linux |
| Build | XcodeGen + xcodebuild, `make build` / `make test-app` / `make qa` |

## Out of scope
New-message compose, search, multiple accounts, push notifications (needs Gmail `watch` → Pub/Sub → a hosted
endpoint → APNs; deliberately avoided), snooze, drafts UI, calendar, contacts.
