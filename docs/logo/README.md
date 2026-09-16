# Logo directions

Source artboards for the minimail logo exploration, built on the wordplay
`minimal` + `i` -> `minimail`.

## Current direction — three dots

`minimal` carries two tittles; `minimail` carries three. The mark is the word
reduced to those three dots, with the accent on the one the name gained — the
same dot `ThreadRowView` already draws against an unread thread.

The tittles sit over letters 2, 4 and 7, so the gaps run short-then-long. The
mark keeps that 2:3 rhythm rather than spacing evenly; that asymmetry and the
single accent dot are what stop it reading as a loading indicator.

| File | Board | Contents |
|---|---|---|
| `Main.dc.html` | Three dots | The mark, icon light/dark, 60/40/29 px, wordmark |
| `DotsVariants.dc.html` | Mark studies | Six arrangements: true rhythm, even, baseline, stair, stacked, inverted |
| `Navigation.dc.html` | In the app | The mark upright as the mailbox switcher, over a drawn inbox |

### Navigation tie-in

`InboxScreen`'s leading toolbar button is `line.3.horizontal`, and its menu has
exactly three destinations — Inbox, Today, Labels. Three lines become three
dots turned upright, with the filled one showing the active mailbox; the state
is already in `InboxScope`.

Open question for the device pass: three dots is iOS's *overflow* idiom, and
this button is navigation rather than more-actions. If testers tap it expecting
Delete and Move, the hamburger stays and the mark lives in the icon only.

## Earlier directions

Kept for the record on the canvas's second page. `Main` grew out of A.

| File | Direction | Idea |
|---|---|---|
| `DirectionA.dc.html` | A — The extra i | The inserted `i` is the logo; its tittle is the inbox unread dot |
| `DirectionB.dc.html` | B — The m is the flap | The envelope flap and the `m`'s vertex are the same wide V |
| `DirectionC.dc.html` | C — Insertion mark | A proofreader's caret inserts the `i` into "minimal" |
| `DirectionD.dc.html` | D — No envelope | A list with one unread dot — no envelope at all |

## Notes

`canvas.json` lays the boards out across two pages.

Colours are the app's own `AccentColor.colorset` (`#007AFF` light, `#0A84FF`
dark); type is the system face the app already uses. Each artboard exposes an
accent tweak so a non-blue can be tried without editing the files.

The published canvas is assembled from these files by the `design` skill; the
assembled page is ~2.5 MB of editor code and is deliberately not committed.
To rebuild it, re-seed from this directory and republish.

Nothing has been adopted in the app yet —
`minimail/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is still the
placeholder and the toolbar still uses `line.3.horizontal`.
