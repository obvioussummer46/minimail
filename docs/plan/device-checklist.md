# minimail — manual device checklist

Architecture §13.1 layer 4: the pass a real device settles that the automated suite (500+ tests) cannot.
Run on a physical iPhone signed into the target Gmail/Workspace account after each TestFlight build.

For each item: **do** the steps, confirm the **expect**, and if it fails follow the **fallback**.

## Auth
- **D1 Sign in.** Tap "Sign in with Google", complete the browser sheet. _Expect:_ lands in the inbox; no "error N" bounce back to the sign-in screen; relaunch stays signed in. _Fallback:_ capture `log stream --predicate 'subsystem BEGINSWITH "com.minimail"'` and file the failing step. (Regression guard for the transient-profile-fetch bounce fixed on `main`.)
- **D2 Admin policy.** If sign-in is blocked, the screen shows the admin-policy help with the client id. _Expect:_ the exact client id is copyable. _Fallback:_ trust the client in the Workspace admin console.
- **D3 Re-auth.** Revoke access in the Google account, pull to refresh. _Expect:_ the re-auth banner appears; tapping it re-signs in without losing the local cache.
- **D4 Sign out.** Settings → Sign Out. _Expect:_ returns to sign-in; local cache cleared; theme/signature/compose style preserved; next sign-in pre-fills the address.

## Inbox / labels
- **D5 First sync.** _Expect:_ inbox fills within a couple of seconds; unread dots correct; date labels sensible in the device locale/timezone.
- **D6 Mailbox switch.** Tap the top-left mailbox menu → Today, then back to Inbox. _Expect:_ works even when **Today is empty** (regression guard for the empty-Today trap). Also try the title menu.
- **D7 Labels sheet.** Open Labels; tap a coloured user label. _Expect:_ Gmail colours render; server unread counts show; "Counts from Gmail · updated …" footer; tapping a label filters the list and hydrates.
- **D8 Pull to refresh.** _Expect:_ spinner, counts update, no duplicate rows.
- **D9 Preview lines.** Settings → Reading → Preview Lines = 5. _Expect:_ inbox snippets grow to 5 lines; setting persists across relaunch.
- **D10 Unread-only toggle.** _Expect:_ filters to unread; toggling back restores.

## Swipes / actions
- **D11 Leading swipe.** Swipe a row right. _Expect:_ it archives **and** marks read in one gesture; the row leaves the inbox; Gmail reflects both (out of inbox, read).
- **D12 Trailing swipe.** Swipe left. _Expect:_ read/unread toggles.
- **D13 Optimistic + offline.** In airplane mode, archive a row. _Expect:_ row leaves immediately; offline banner; on reconnect the op syncs, no duplicate.

## Thread
- **D14 Open thread.** _Expect:_ **newest message on top**; newest + unread expanded, older collapsed; HTML renders; no layout jump when a body lands.
- **D15 Remote images.** A newsletter with remote images. _Expect:_ images off by default; "Load images" reveals them per message; the sender cannot ping you until you tap.
- **D16 Attachments.** Open a thread with a PDF. _Expect:_ chip shows name/size; tapping downloads and previews; large attachments are refused before download.
- **D17 Dark mode.** Toggle system dark mode. _Expect:_ chrome and message bodies adapt; no white flash; a forced light/dark theme (Settings → Appearance) overrides.

## Compose / send
- **D18 Reply all.** _Expect:_ recipients pre-filled minus yourself; subject `Re:` not doubled; quoted original included; signature appended when enabled.
- **D19 Forward.** _Expect:_ `Fwd:` subject; no recipients; attachments carried and toggleable; Send disabled until a recipient is added.
- **D20 Send.** Send a reply. _Expect:_ appears in the outbox briefly, then in the Gmail thread; failure surfaces in the Outbox section with retry/discard.
- **D21 Signature editor.** Settings → Signature: edit HTML, import from Gmail, save. _Expect:_ live preview (no remote images); `data:` image warning; oversized HTML blocked.

## Settings / system
- **D22 Theme picker.** System / Light / Dark apply immediately app-wide.
- **D23 Badge.** Enable "Show Unread Count on Icon". _Expect:_ system prompt appears once; icon badge matches inbox unread; denying shows the "Open Settings" help; disabling clears the badge.
- **D24 Full resync.** Settings → Advanced → Full Resync Now. _Expect:_ confirmation, then the inbox re-downloads; History ID updates.
- **D25 Background refresh.** Background the app, wait, foreground. _Expect:_ new mail appears without a manual pull (best-effort; iOS schedules it).
- **D26 Dynamic Type.** Raise the system text size. _Expect:_ rows and thread text scale; no clipping.
