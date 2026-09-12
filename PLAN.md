# minimail

Minimal, native, fast Gmail client for iPhone. Work account: Google Workspace (newtelco.de).

**The plan lives in [`docs/plan/README.md`](docs/plan/README.md).** Start there.

## Goals
- Feels like a system app. SwiftUI, iOS 17+, no third-party UI.
- Blazing speed: local-first, the UI never waits on the network.
- No battery drain: no timers, no polling, no sockets, no prefetching.
- Only stage-1 features. Nothing speculative.

## Stage 1 features
- [ ] Get mail (Inbox), pull to refresh
- [ ] Today view
- [ ] Unread-only view
- [ ] Gmail labels with counts
- [ ] Open thread, read HTML safely
- [ ] Mark read / unread, show read state
- [ ] Archive
- [ ] Reply all
- [ ] Forward (with attachments)
- [ ] HTML signature
- [ ] Default font and text colour for outgoing mail
- [ ] Dark mode, with a theme system open to more themes later

## Stack
| Area | Choice |
|---|---|
| UI | SwiftUI, iOS 17 floor |
| Auth | AppAuth-iOS 3.0.0, PKCE, tokens in Keychain |
| API | Gmail REST v1 over URLSession, scope `gmail.modify` only |
| Sync | `history.list` delta sync, optimistic actions through an outbox |
| Storage | GRDB 7.11.1 (SQLite, WAL) |
| Email HTML | SwiftSoup sanitiser, one pooled WKWebView, JavaScript off, remote images off |
| Core logic | `MailCore` local package, zero dependencies, tests run on Linux |
| Build | XcodeGen + xcodebuild, `make qa` |

Three dependencies total. Everything else is hand-written.

## Milestones
| | Scope | Modules |
|---|---|---|
| M1 | Project, MIME, Gmail model, auth, API client, database | 01–06 |
| M2 | Sync, HTML rendering, inbox list, thread view, labels | 07–10, 12 |
| M3 | Compose: reply-all and forward | 11 |
| M4 | Settings, themes, signature, QA, TestFlight | 13, 14 |

121 tasks. Each names its files, its definition of done and its verification command.

## Owner to-do (manual, cannot be scripted)
- [ ] Google Cloud project inside the newtelco.de org, OAuth consent type **Internal**
- [ ] Enable Gmail API
- [ ] iOS OAuth client for bundle id `de.newtelco.minimail`
- [ ] Workspace admin: trust the client (else sign-in fails with `admin_policy_enforced`)
- [ ] Apple Developer account, register the bundle id
- [ ] A Mac or macOS runner with Xcode 26.x

## Out of scope for stage 1
New-message compose, search, multiple accounts, push notifications, snooze, drafts UI, calendar, contacts.
