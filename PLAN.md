# minimail — plan

Minimal, native, fast Gmail client for iPhone. Work account: Google Workspace (newtelco.de).

## Principles
- Native SwiftUI, iOS 17+, zero third-party UI. Feels like a system app.
- Gmail REST API (not IMAP). Delta sync via `history.list`. No polling timers.
- Local-first: SQLite cache, UI never waits on network.
- Do less: stage 1 features only, nothing speculative.

## Stack
| Area | Choice | Why |
|---|---|---|
| UI | SwiftUI + `NavigationStack` | iOS-native look, minimal code |
| Auth | AppAuth-iOS (OAuth 2.0 PKCE, `ASWebAuthenticationSession`) | No Google SDK bloat, tokens in Keychain |
| API | `URLSession` async/await, hand-written Gmail client | Small, controllable, no SDK |
| Storage | GRDB (SQLite) | Predictable speed, FTS later, no SwiftData surprises |
| HTML body | `WKWebView` (sandboxed, remote images off by default) | Correct rendering, privacy, battery |
| Compose | `UITextView` (plain text) + HTML signature appended on send | Simple, reliable |
| Settings | `UserDefaults` + Codable `Preferences` struct | Trivial |
| Tests | XCTest (MIME builder, sync engine, date/“today” logic) | Cheap, catches regressions |

Single scope: `https://www.googleapis.com/auth/gmail.modify` (read, label, archive, send).

## Google Cloud setup (one-time)
- [ ] Create GCP project **inside the newtelco.de org** → OAuth app type **Internal** → no verification review needed
- [ ] Enable Gmail API
- [ ] OAuth client: iOS, bundle id `de.newtelco.minimail`, redirect `com.googleusercontent.apps.<id>:/oauth2redirect`
- [ ] Workspace admin: ensure app is allowed/trusted (Security → API controls)

## Architecture
```
minimail/
  App/            entry, DI container, theme injection
  Auth/           AppAuth flow, Keychain token store, auto-refresh
  Gmail/          GmailAPI (endpoints), DTOs, MIME builder/parser, base64url
  Store/          GRDB schema, migrations, repositories (Message, Thread, Label)
  Sync/           SyncEngine: full sync → historyId → delta sync; outbox for sends/label ops
  Features/
    Inbox/        list (Inbox, Today, Unread, Label) + filter chips
    Thread/       message view (WKWebView), actions bar
    Compose/      reply-all / forward editor, signature + font/color applied
    Labels/       label list (system + user, unread counts)
    Settings/     account, signature (HTML), default font/color, theme
  Theme/          Theme protocol, Light/Dark, ThemeStore
  Support/        Date helpers ("today"), HTML sanitizer, logging
```

## Data model (SQLite)
- `label(id, name, type, color, unread_count, sort_order)`
- `thread(id, history_id, snippet, last_date, is_unread, in_inbox)`
- `message(id, thread_id, from, to, cc, subject, date, snippet, is_unread, label_ids JSON, body_html, body_text, has_attachments, raw_headers JSON)`
- `attachment(id, message_id, filename, mime, size)` (metadata only, fetch on demand)
- `outbox(id, kind, payload JSON, created_at, attempts)` (send / modify ops, retried, idempotent)
- `sync_state(key, value)` → `history_id`, `last_full_sync`

## Sync strategy (speed + battery)
1. First launch: `threads.list` (INBOX, ~50) → `messages.get?format=metadata` batched → store `historyId`.
2. Foreground / pull-to-refresh: `history.list(startHistoryId)` → apply `messagesAdded / labelsAdded / labelsRemoved` only.
3. Body fetched lazily on open (`format=full`), cached. Attachments never prefetched.
4. Optimistic UI: archive / read / unread applied locally instantly → `outbox` → `messages.modify` (batch API).
5. Background: single `BGAppRefreshTask` (system-scheduled, ≥15 min, opportunistic). No sockets, no timers, no location, no analytics.
6. Stage 2 option: Gmail `watch` + Pub/Sub → APNs push (needs tiny server; skip for now).

## Stage 1 — feature todo
### Auth
- [ ] OAuth login, token refresh, sign-out, Keychain storage
### Inbox
- [ ] Inbox list: sender, subject, snippet, time, unread dot, label chips
- [ ] Views: **Inbox**, **Today** (received today, local tz), **Unread only**
- [ ] Filter chip: unread toggle on any view
- [ ] Pull-to-refresh (delta sync)
- [ ] Swipe: archive (leading), read/unread toggle (trailing)
### Labels
- [ ] Label list (system + user labels, Gmail colors, unread counts)
- [ ] Tap label → filtered list
### Thread / message
- [ ] Render HTML in WKWebView (sanitized, remote images blocked, "load images" button)
- [ ] Mark read on open; manual read/unread toggle
- [ ] Actions: **Reply all**, **Forward**, **Archive**, read/unread
- [ ] Attachments: list + open via QuickLook (download on tap)
### Compose (reply-all / forward)
- [ ] Recipients prefilled (reply-all: dedupe self, honor Reply-To)
- [ ] Quoted original (HTML) + `In-Reply-To` / `References` / `threadId`
- [ ] Forward: original body + attachments passthrough
- [ ] Body wrapped with default font/color CSS; HTML signature appended
- [ ] `messages.send` via outbox with retry; draft saved if send fails
### Settings
- [ ] HTML signature editor (raw HTML textbox + live preview)
- [ ] Default font (family, size) and text color
- [ ] Theme picker: System / Light / Dark
- [ ] Remote images default on/off
- [ ] Account: email shown, sign out

## Theming (future-proof)
- `protocol Theme { name, colors: (bg, surface, text, secondaryText, accent, unread, separator), fonts }`
- Built-ins: `LightTheme`, `DarkTheme`; `SystemTheme` follows `colorScheme`
- `ThemeStore` (`@Observable`) injected via environment; all views use semantic tokens only, never raw colors
- Adding a theme later = one new struct + registry entry (later: JSON-defined themes)

## Performance / battery rules
- No network on the main thread, no work while app is backgrounded except BG refresh
- Lists render from SQLite only; `LazyVStack`/`List` with stable IDs
- Batch API for `messages.get` / `modify` (≤50 per request)
- `format=metadata` + `metadataHeaders=` for list, `full` only on open
- HTML sanitized once on fetch, cached; WKWebView pooled (1 instance reused)
- Images off by default; no tracking pixels
- Cold start target < 400 ms to first list paint; refresh < 1 s on delta

## Milestones
1. **M1 Skeleton (wk 1)** — Xcode project, GRDB, AppAuth login, inbox list from API, dark mode
2. **M2 Read (wk 2)** — thread view, HTML render, labels, Today/Unread views, read/unread, archive, delta sync
3. **M3 Write (wk 3)** — MIME builder, reply-all, forward, signature, font/color, outbox
4. **M4 Polish (wk 4)** — settings UI, theme protocol, BG refresh, tests, TestFlight

## Out of scope (stage 1)
Compose new mail, search, multiple accounts, push notifications, snooze, drafts UI, calendar, contacts.
