# Clipboard history spec · shell-engineer, platform-engineer · ADR-0034

The clipboard history of macOS 26/27 Spotlight, in Grassfield's Search (never called "Spotlight" in the UI, §14), with the
power of Windows' clipboard history: pins, formats, a direct key. Decisions: ADR-0034 (owner, 2026-10-27, Q1 to Q8). Steps:
0 docs (this file, the ADR); 1 helper, shell service, settings keys; 2 the view in Search and Super+V; 3 Settings > Search
(after the Settings PRs #8, #9 and #10 are on main).

## macOS reference behavior (described in words)
Checked on 2026-10-27. VERIFIED = an Apple page or a capture shows it; PRESS = third-party articles only; UNKNOWN = no source.

| # | Behavior | Status | Source |
|---|---|---|---|
| M-1 | ⌘Space opens Spotlight, ⌘4 shows the clipboard history; the Clipboard button to the right of the field does the same (⌘1 Applications, ⌘2 Files, ⌘3 Actions) | VERIFIED | Apple A, C; capture W-36 (the "⌘4 for Clipboard" first-run card) |
| M-2 | Off until allowed: the first visit asks. macOS 26.0: title "Clipboard Search", "Spotlight can search and display items you've copied to your clipboard. Personal and sensitive information may appear in search results. You can manage Clipboard Search at any time in Spotlight Settings.", buttons "Not Now" and "Turn On"; macOS 27: the button is "Allow" | VERIFIED | Apple A; W-35 |
| M-3 | The field shows the clipboard symbol and the placeholder "Clipboard"; typing searches the history | VERIFIED | Apple A; W-38, W-40 |
| M-4 | A row: a thumbnail (a page with the text, or the picture) with the source app's icon as a badge at its bottom right; the title (the text's first line, or a file name); the subtitle "Text · Copied 11:23 AM", "PNG image · Copied 11:01 AM"; a round copy button at the right | VERIFIED (26.0) | W-38 |
| M-5 | The copy button (or ⌘C on the selected row) puts the item back on the clipboard without pasting | VERIFIED | Apple A; W-38; PRESS Cult of Mac |
| M-6 | Return, or a click, on a row pastes the item into the frontmost app (Spotlight closes); a double-click pastes | PRESS (Cult of Mac, NotchBay; Office Watch: double-click); ClipBook says Spotlight only copies. The owner's brief settles it: paste | — |
| M-7 | The row menu (secondary click): Paste, Copy, Delete Item (26.0). A later build is reported with Paste, Share, Open, Remove | VERIFIED (26.0) / PRESS | W-37; Make Tech Easier |
| M-8 | The More button (…) to the right of the field: Clear History, Settings… | VERIFIED | Apple A; W-40 |
| M-9 | Settings > Spotlight: "Results from Clipboard" (switch), "Clipboard history is available in Spotlight" for 30 minutes, 8 hours or 7 days (8 hours by default; 26.0 had 8 hours only), "Clear Clipboard History" then "Clear" | VERIFIED (27) | Apple B; W-39 (26.0: "Clipboard Search … available for eight hours") |
| M-10 | Copies an app marks as concealed or transient (Apple's Passwords, password managers) are not kept; ordinary copies of a password are | PRESS | Make Tech Easier, NotchBay, ClipBook |
| M-11 | Pasting from the history drops the formatting (plain text) | PRESS | Cult of Mac, ClipBook |
| M-12 | Text, links (as text), images, files are kept; the history stays on the Mac | PRESS (W-38 shows text, a URL as Text, PNG images) | Paste blog, NotchBay, W-38 |
| M-13 | Space opens a result in Quick Look; Return opens it | VERIFIED for Spotlight results in general | Apple C |
| M-14 | Item limit; what happens at logout or when the history is turned off; a key that deletes an item; the macOS 27 view's exact look; pinning (none) | UNKNOWN / none | — |

## Windows reference behavior (described in words)
Windows 11, checked on 2026-10-27. VERIFIED = Microsoft Support; PRESS = third-party guides.

| # | Behavior | Status | Source |
|---|---|---|---|
| W-1 | Windows key + V opens the clipboard history anywhere; the first time it offers "Turn on" | VERIFIED | Microsoft A |
| W-2 | Text, HTML and bitmaps; at most 4 MB an item; the 25 latest entries, the oldest unpinned removed first | VERIFIED | Microsoft A |
| W-3 | Pin: a pin icon on the item; a pinned item is never pushed out and goes to the front | VERIFIED (pin) / PRESS (icon, front) | Microsoft A; PCWorld, Eleven Forum |
| W-4 | The history is cleared at each restart, except pinned items | VERIFIED | Microsoft A |
| W-5 | "See more" (…) on an item: Delete; for text, "Paste as Text" (pasted without formatting) | VERIFIED (Delete) / PRESS (Paste as Text) | Microsoft A; GeekRewind, Eleven Forum |
| W-6 | "Clear all" at the top of the panel and Settings > System > Clipboard > "Clear clipboard data" > "Clear": everything except pinned items | VERIFIED | Microsoft A |
| W-7 | Sync across devices through a Microsoft or work account (automatic or manual) | VERIFIED | Microsoft A |
| W-8 | Suggested actions on a copied phone number or date | PRESS: deprecated by Microsoft | TechRadar, Thurrott |
| W-9 | Search inside the history; keyboard keys inside the panel (delete, pin) | UNKNOWN (no source found) | — |

Sources: Apple A "Search your Clipboard history in Spotlight on Mac" (support.apple.com/guide/mac-help/mchl40d5b86b/mac,
macOS 27 and 26); Apple B "Spotlight settings on Mac" (…/mchl54d95e8a/mac, macOS 27); Apple C "Spotlight keyboard shortcuts"
(…/mh26783, macOS 27); W-35 to W-40: Office Watch, "macOS 26 clipboard history" (office-watch.com/2025/macos-26-clipboard-history,
captures of macOS 26.0); Cult of Mac "Mac clipboard history"; Make Tech Easier "check Mac clipboard history"; NotchBay
"macOS Tahoe clipboard history"; ClipBook "how to see clipboard history on Mac"; pasteapp.io "macOS Tahoe clipboard history";
Microsoft A "Clipboard in Windows" (support.microsoft.com/windows/clipboard-in-windows-c436501e-985d-1c8d-97ea-fe46ddf338c6);
PCWorld "how to permanently save clips in Windows 11's clipboard"; Eleven Forum tutorials (pin and unpin, paste as plain text,
clear clipboard data); GeekRewind "paste as plain text from clipboard history in Windows 11"; TechRadar and Thurrott on the
deprecation of suggested actions. 512 Pixels (macOS 26 and 27 libraries) has Spotlight and Settings > Spotlight captures but no
clipboard view. Reference captures are downloaded to `design/reference/clipboard/` (git-ignored), never committed.

## Measurements
From W-38 (macOS 26.0, light). Scale 2 px/pt: its row pitch is 112 px, the 56 pt pitch of the 512 Pixels
`26-Tahoe-Spotlight.png` (2880 px for 1440 pt). Grassfield's Search follows macOS 27 (ADR-0024; rows 63, icon 36 at 26,
text at 80, `docs/specs/search.md`), so the clipboard rows take the 27 Search rows and only the parts specific to the clipboard
are measured here.

| Element | 26.0 measurement | Grassfield (27 structure) |
|---|---|---|
| Row pitch | 56 pt | 63 (Search rows) |
| Title | cap height 12.5 pt (≈ 17.7 pt type), one line, ellipsis | 17 (Search title) |
| Subtitle | cap height ≈ 10.5 pt (≈ 15 pt type), "Kind · Copied time" | 15 (Search subtitle) |
| Thumbnail | ≈ 36 pt box; badge ≈ 10 pt at its bottom right, overhanging | 36 at 26 (Search icon); badge 10, new token |
| Copy button | disc 26.5 pt (53 px); fill (221, 221, 222) on (247, 247, 249): black at ≈ 0.10; glyph (66, 67, 69) | disc 26, `colors.fill` at the control fill opacity, centred on the row, its right edge 12 from the selection's right edge (to measure on a 27 capture) |
| Pin button | none on macOS (Windows has a pin icon on the item) | the copy button's disc and fill, 8 to its left, on the selected or hovered row; on a pinned row a filled pin is always shown there |
| More button | circle outline 20 pt, right end of the field | 20 in the capsule, right of the query |
| Field symbol | ≈ 24 × 29 pt (two stacked pages) | the magnifier's size and place in the capsule (26) |
| Selection (26.0) | accent fill, full pitch | neutral fill as Search (ADR-0024: `search.selectionFillOpacity`, inset 12, radius 18) |

The F1 target (ADR-0024): geometry within ±1 pt, tints within ±0.1, A2 contrast. A macOS 27 capture of the clipboard view is
missing: step 2 measures one if it can be found (or the owner provides it) before its pull request, and says otherwise. The pin
glyph is Grassfield's own symbol (no Apple or Microsoft artwork).

## Purpose and non-goals
Purpose: recent copies (text with its formatting, images, files) searchable in Search, pinned when they are worth keeping,
put back on the clipboard or pasted into the frontmost app in one step, private by construction. Non-goals: sync between
machines (nothing leaves the machine), suggested actions (deprecated by Microsoft), the emoji, GIF and symbol tabs Windows
shows in the same panel (not the clipboard), colours (no shared colour type on Linux), link previews or any network access,
the primary selection, Share (no Linux equivalent).

## Functional requirements
| ID | Requirement | Step |
|---|---|---|
| CB-1 | `grassfield-clipboard-helper` records copies as ADR-0034 §1 decides: kinds, text with its HTML and RTF parts, caps, refusal before any read, dedupe, history limits (100 items, 64 MiB), retention (30 min, 8 h, 7 days; default 8 h), pins (50, 32 MiB, never expired) | 1 |
| CB-2 | The shell service `Clipboard` (shell/services) starts the helper only while `search.clipboard.enabled` is true, answers each offer (`Y`/`N`, ADR-0034 §2), pauses it while locked, resumes after, applies retention, the history store switch, `clearedAt` and `pinnedClearedAt`; exposes the items to Search | 1 |
| CB-3 | Settings keys in `config/schema/grassfield.schema.json`: `search.clipboard.enabled` (false), `.retention` ("30m", "8h", "7d"; "8h"), `.keepOnDisk` (false), `.clearedAt` (0), `.pinnedClearedAt` (0) | 1 |
| CB-4 | The pinned store (always) and the opt-in history store (ADR-0034 §5) | 1 |
| CB-5 | Search's Clipboard view: ⌘4 (Super+4 is forwarded as Ctrl+4; Ctrl+4 too), the Clipboard button to the right of the empty field, and Super+V from anywhere (opens Search in the view; again closes it); the field shows the clipboard symbol and the placeholder "Clipboard"; Backspace in an empty field, or ⌘1/⌘2/⌘3, leaves the view | 2 |
| CB-6 | The first visit while the history is off (⌘4, the button or Super+V) shows the prompt (M-2, W-1): "Not Now" leaves it off, "Turn On" sets `search.clipboard.enabled` through `settings apply`; recording starts with the next copy; existing pins show again | 2 |
| CB-7 | Rows (M-4): pinned items first (newest pin first) with a pin mark, then the history newest first, all filtered by the query (the helper's search); empty: "No Items"; a query with no match: "No Results for …" (Search's notice) | 2 |
| CB-8 | Paste: Return, Enter, a click, the menu's Paste (with formatting when the item has it); Shift+Return and the menu's Paste as Plain Text (text items with formatting) paste the plain text only (ADR-0034 §4); the copy button, ⌘C (Ctrl+C) and the menu's Copy only copy and leave Search open with a short "Copied" state on the row | 2 |
| CB-9 | Delete one item: the menu's Delete Item, or Ctrl+Backspace on the selected row while the field is empty (no macOS key is documented, M-14); the selection moves to the next row; a pinned item is deleted from the disk too | 2 |
| CB-10 | More menu (…): Clear History (at once, as the 26.0 menu shows no confirmation; pinned items stay, W-6) and Settings… (opens Settings > Search) | 2 |
| CB-11 | Item preview: Space on a selected row while the field is empty, or ⌘Y (Ctrl+Y) at any time, opens a preview panel next to Search (text: the plain part, up to 64 KiB, plain text only, scrollable, never rendered as HTML; image: a preview at most 1,024 px on its long side made on demand by the helper in the runtime directory and deleted when the panel closes; files: names and kinds); Space or Esc closes it | 2 |
| CB-12 | Keyboard and mouse parity: every action has both (table below); the row menu opens with a secondary click, the Menu key or Shift+F10 | 2 |
| CB-13 | Settings > Search: "Results from Clipboard", "Clipboard history is available in Search for" (30 minutes, 8 hours, 7 days), "Clear Clipboard History…" (asks; "Clear" writes `clearedAt`; the dialog's "Also delete pinned items" also writes `pinnedClearedAt`), "Keep clipboard history after logging out" | 3 |
| CB-14 | Every string in English and French (`translations/`), Search's names only (never "Spotlight"); the Super+V binding's description in `apps/settings/qml/Bindings.js` and the French catalog | 2, 3 |
| CB-15 | Pin and unpin: the row's pin button, the menu's Pin / Unpin, ⌘P (Ctrl+P) on the selected row; a pin past 50 items or 32 MiB is refused with "Pinned items are full"; pinned items never expire, are never pushed out, and survive logout, restarts and Clear History (W-3, W-4, W-6) | 2 (1 for the store) |

### Keyboard and mouse
| Action | Keyboard | Mouse |
|---|---|---|
| Open the view | Super+V; or ⌘Space then ⌘4 | the Clipboard button right of the field |
| Move | ↑ ↓ | hover |
| Paste | Return, Enter | click, double-click |
| Paste as plain text | Shift+Return | the menu's Paste as Plain Text |
| Copy only | ⌘C (Ctrl+C) | the copy button |
| Pin, unpin | ⌘P (Ctrl+P) | the pin button, the menu |
| Row menu | Menu key, Shift+F10 | secondary click |
| Delete item | Ctrl+Backspace (empty field), or the menu | the menu's Delete Item |
| Preview | Space (empty field), ⌘Y (Ctrl+Y) | — (the menu has no preview item on macOS) |
| Clear (unpinned) | the More menu (Tab reaches it after the rows) | More (…) > Clear History |
| Leave the view | Backspace in the empty field, ⌘1–⌘3 | — |
| Close | Esc (clears the query first, as Search), Super+V | click outside |

## Privacy requirements
| ID | Requirement |
|---|---|
| PV-1 | A copy whose types include `x-kde-passwordManagerHint` (any value) or an nspasteboard.org concealed, transient or auto-generated type is never recorded, and its data is never requested (ADR-0034 §1b); it can therefore never be pinned |
| PV-2 | Nothing is recorded while the session is locked or locking: the helper has no data-control device then, the shell answers `N`, and the first selection after the unlock is skipped (ADR-0034 §6) |
| PV-3 | Nothing is recorded while a screen-share-protected password manager is the active window (`privacy.lua`) |
| PV-4 | Off switch (CB-13, CB-6): turning off deletes the unpinned items; clear (CB-10, CB-13) deletes the unpinned items; "Also delete pinned items" (CB-13) deletes everything, memory and disk |
| PV-5 | No network: the helper links no network module; the shell fetches nothing for an item (no link preview, no favicon, no remote icon, HTML never rendered) |
| PV-6 | No content in logs: counts, kinds, sizes and reasons only; titles, text, file names, URLs and hashes never appear (a canary test) |
| PV-7 | Caps and limits of ADR-0034 §1; thumbnails at most 256 px, previews at most 1,024 px, both in the runtime directory, 0600 |
| PV-8 | Text is shown as plain text only (`textFormat: Text.PlainText`, `scripts/dev/check-textformat.py`): a copied string cannot inject rich text |
| PV-9 | The view is never shown while locked (GF-116 `SessionState.refuses`) and closes when the lock engages; Super+V is refused while locked |
| PV-10 | Tests never read the owner's clipboard or session: the fake server, scratch `XDG_RUNTIME_DIR`, `HOME` and state; in a dev session nothing is captured without `GRASSFIELD_CLIPBOARD_DISPLAY` |
| PV-11 | Only an explicit pin writes an item to the disk without the opt-in switch; the pinned store is read only by the helper, with the bounds of ADR-0034 §5 |

## Strings (English, French)
| English | French |
|---|---|
| Clipboard | Presse-papiers |
| Clipboard history (binding description) | Historique du presse-papiers |
| Clipboard Search | Recherche dans le presse-papiers |
| Search can find and show the items you copy. Personal and sensitive information may appear in the results. You can change this at any time in Search settings. | La Recherche peut retrouver et afficher les éléments que vous copiez. Des informations personnelles et sensibles peuvent apparaître dans les résultats. Vous pouvez modifier ce choix à tout moment dans les réglages de la Recherche. |
| Not Now · Turn On | Plus tard · Activer |
| Text · Formatted Text · %1 image · Files · %n Items | Texte · Texte mis en forme · Image %1 · Fichiers · %n éléments |
| Copied %1 | Copié à %1 |
| Copied | Copié |
| Paste · Paste as Plain Text · Copy · Pin · Unpin · Delete Item | Coller · Coller en texte brut · Copier · Épingler · Désépingler · Supprimer l'élément |
| Pinned | Épinglé |
| Pinned items are full | Le nombre maximal d'éléments épinglés est atteint |
| Clear History · Settings… | Effacer l'historique · Réglages… |
| No Items | Aucun élément |
| Clipboard history is off in development (set GRASSFIELD_CLIPBOARD_DISPLAY) | dev only, English |
| Clipboard history needs a compositor with ext-data-control | L'historique du presse-papiers nécessite un compositeur compatible ext-data-control |
| Results from Clipboard | Résultats du presse-papiers |
| Clipboard history is available in Search for | L'historique du presse-papiers est disponible dans la Recherche pendant |
| 30 minutes · 8 hours · 7 days | 30 minutes · 8 heures · 7 jours |
| Clear Clipboard History… · Clear · Also delete pinned items | Effacer l'historique du presse-papiers… · Effacer · Supprimer aussi les éléments épinglés |
| Keep clipboard history after logging out | Conserver l'historique après la déconnexion |

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| CB-1, CB-15, PV-1, PV-7 | `tests/unit/clipboard-helper/tst_cliplogic.cpp` (gtest, ASan build too): type choice, HTML and RTF parts and their caps, the plain part made from HTML, hint and marker refusal, caps, UTF-8 and Latin-1, dedupe (also against a pin), history and pin limits, retention with the clock set back and forward (pins never expire), escaping of the line protocol | L0 |
| CB-1, CB-4, CB-15, PV-1, PV-2, PV-11 | `tests/shell/clipboard_helper.sh`: the helper against `tests/fixtures/fake-clipboard-server` in a `mktemp -d` runtime directory; every kind; HTML with and without plain text; a hinted copy (the server records no receive request); a source that never closes (2 s); oversized data; the own-copy marker; Paste as Plain Text offers no HTML; pause and resume (first selection skipped); the stores (modes 0700/0600, pins present after a helper restart, a symlinked or oversized index deleted, history expiry at load, history store deleted when switched off, `--clear-pinned`) | L0 |
| CB-2, CB-8, PV-2, PV-3 | `tests/unit/tst_clipboard.qml`: offer answers (locked, off, protected window), the paste request (address validation, terminal list equal to `forwarding.lua`'s, refused when locked, when another window is active, after 1 s), the clear keys (unpinned only, then everything) | L0 |
| PV-6 | log canary: a copy of a unique string through the fake server, pinned then unpinned, then the helper's and the shell's logs do not contain it | L0 |
| PV-8 | `scripts/dev/check-textformat.py` | L0 |
| CB-5 to CB-12, CB-15 | headless Search scenario with a fake helper (`GRASSFIELD_CLIPBOARD_HELPER`): view, rows, pinned first, menus, pin, delete, clear, preview, keyboard map | L1 |
| CB-5 | `search clipboard` in the IPC inventory (action, caller SUPER+V), refused while locked | L0 (`tests/security/ipc_inventory.sh`, `lock_surfaces`) |
| CB-8 | nested: a real copy in a test window, Return pastes into it, Shift+Return pastes plain text into a rich-text app; Search opened over window A, A closed meanwhile: nothing is pasted | L1 (integrator) |
| PV-2, PV-9 | nested: copy while locked (a program running `wl-copy` under the lock): absent after the unlock | L1 (integrator) |
| CB-5 to CB-15 | `just shot` light and dark, en and fr; geometry and tints against the measurements, A2 | visual |

## Known limitations
- Wayland does not say which client made a copy: the source badge is the app that was frontmost (ADR-0034 §3).
- A program the history pastes into must accept Ctrl+V (Ctrl+Shift+V in terminals); an app with another paste key gets the
  item on its clipboard only.
- Formatted text is pasted as the source app produced it; HTML may reference remote images that the target app chooses to
  load (as with any paste). Grassfield itself never renders it.
- When the helper exits (shell restart, history turned off) while it owns the clipboard, the clipboard becomes empty, as with
  any Wayland app that owns it.
- The view is not hidden from screen capture or sharing, as on macOS.
- A password manager that neither sets the hint nor is in the screen-share list is recorded like any app (macOS and Windows
  have the same limit); such a copy is deleted with the history unless the user pins it.
- Without the opt-in history store the unpinned items end at logout and when the shell restarts; pinned items stay.
- A deleted pinned item's blocks can stay on the disk until reused (btrfs, SSD); Omarchy's full-disk encryption covers them.
- A copy made in the instant a foreign locker takes the lock, before the shell sees it, can be recorded (ADR-0034 §4 and §6);
  the shell itself locks through its own module, which pauses capture first.
- A compositor without `ext-data-control-v1` (Hyprland 0.56.2 has it): no history (the view says so).

## Not verified (step 0)
- The macOS 27 clipboard view (no capture), M-6 (paste) beyond press sources, M-14; W-9.
- In Hyprland 0.56.2's Lua: the format of a window object's `address` and the `address:` selector of `send_key_state`
  (nested, step 1, before the paste code).
- Real copies from KeePassXC, 1Password, Bitwarden, Firefox's password manager, a GTK and a Qt app (with HTML), XWayland
  (owner or integrator, nested).
