# Logo directions

Source artboards for the minimail logo exploration, built on the wordplay
`minimal` + `i` -> `minimail`.

| File | Direction | Idea |
|---|---|---|
| `Main.dc.html` | A — The extra i | The inserted `i` is the logo; its tittle is the inbox unread dot. |
| `DirectionB.dc.html` | B — The m is the flap | The envelope flap and the `m`'s vertex are the same wide V. |
| `DirectionC.dc.html` | C — Insertion mark | A proofreader's caret inserts the `i` into "minimal". |
| `DirectionD.dc.html` | D — No envelope | A list with one unread dot — no envelope at all. |

`canvas.json` lays the four out on one canvas.

Colours are the app's own `AccentColor.colorset` (`#007AFF` light, `#0A84FF`
dark); type is the system face the app already uses. Each artboard exposes an
accent tweak so a non-blue can be tried without editing the files.

The published canvas is assembled from these files by the `design` skill; the
assembled page is ~2.5 MB of editor code and is deliberately not committed.
To rebuild it, re-seed from this directory and republish.

Nothing here has been adopted yet — `minimail/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
is still the placeholder. Picking a direction is the next step.
