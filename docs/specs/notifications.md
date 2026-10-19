# Notifications spec · shell-engineer · M2

UI naming (renamed 2026-10-18, owner decision): the internal "Notification Center" (`NotificationCenter.qml`, IPC `toggleCenter`) is shown to the user as "Notifications" (fr « Notifications »); the do-not-disturb mode is "Do Not Disturb" (fr « Ne pas déranger »), not "Focus".
Status: implemented in M2 (see "Implementation notes"); N10 (lock screen) belongs to the lock module.

## macOS reference behavior (described in words)
- Banners slide in at the top-right under the menu bar, ~344 pt wide, rounded ~16 pt, material background,
  app icon left, bold title, body up to 4 lines, relative time ("now", "2m ago") top-right. They stay ~5 s
  (alerts stay until acted on), hovering pauses dismissal, a swipe/drag to the right dismisses, a close (×)
  button appears on hover at the top-left corner.
- Multiple banners stack vertically with 6 pt gaps; same-app notifications group with a count in the
  Notifications column.
- The Notifications column opens from the clock in the menu bar (click). macOS model (F1 gap 7): no full-height panel; a
  344 pt column of floating glass cards, the width of a banner, 16 pt from the right edge and below the bar. No title capsule (the
  reference has none); cards are grouped by app, newest first; the first card of a group carries the
  app name and the count; widgets placed in the Center follow as glass tiles; the footer (Edit Widgets pill, 24 pt close circle) is
  centred under the column, 16 pt below the last card (at the bottom when the list fills the column). The banners hide while the column or Quick Settings is open.
  macOS 26 clear model (owner decision 2026-10-19, batch 4): there is NO permanent "Clear All" pill. Hovering (or focusing) a card
  shows a small round x at its top-left corner (accessible name "Close", fr « Fermer »); hovering a group shows, on its header card,
  "Show Less" (when the group was expanded with "Show All") and a round x that grows into a "Clear All" pill (fr « Tout effacer ») under
  the pointer or the keyboard focus and clears the whole group. A cleared card (or every card of a cleared group) slides out to the
  right while it fades (`motion.normal`), then the column reflows (cards below slide up). Keyboard: Tab reaches each card, then
  its x, then the group controls; Space or Return on the x clears; Delete or Backspace on a focused card clears it and focuses the next card
  (the previous one when it was the last, the column when none is left).
  Esc, the close circle or a click outside the cards closes.
- Do Not Disturb (from Quick Settings) silences banners; the menu bar shows a moon icon.

## Purpose and non-goals
Single `org.freedesktop.Notifications` server for the session (Quickshell `Quickshell.Services.Notifications`),
banners, history (ADR-0004), Notifications panel, DND. Non-goals: notification sounds beyond one
Grassfield sound (later), cross-device sync.

## Functional requirements
1. N1 Server registers `org.freedesktop.Notifications`; capabilities: body, body-markup (sanitized subset),
   actions, icon-static, persistence, inline-reply only if Quickshell supports it.
2. N2 Banner per notification; timeout = hint/expire_timeout, default 5 s; `urgency=critical` never auto-expires.
3. N3 Hover pauses the timeout; drag right > 30 % width or × button dismisses (calls `dismiss()`).
4. N4 Clicking the banner invokes the `default` action if present and focuses the sender window if known.
5. N5 Actions render as buttons (max 3 visible, rest in a "More" menu); each invokes the real action.
6. N6 History persisted per ADR-0004 (0600, ≤ 200 entries, ≤ 7 days, transient not stored).
7. N7 Notifications panel: opens from the clock or `SUPER+N`; grouped by app; per-card x and per-group "Clear All" (hover/focus; no global Clear All).
8. N8 DND: toggle (Quick Settings); suppresses banners except critical; menu bar moon indicator.
9. N9 Markup is sanitized (allow b, i, u, a href shown as text); images limited to 256 px.
10. N10 Never shown on the lock screen by default (L4).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| N1 | `notify-send` from inside nested → banner screenshot; `busctl --user` shows the name owned by qs | L1 |
| N2/N3 | scripted: send 3, wait 6 s, only critical remains | L1 |
| N5 | `notify-send -A ok=OK` → click via `wtype`/IPC → `notify-send` prints `ok` | L1 |
| N6 | restart shell → history restored; file mode 0600 | L1 |
| N9 | unit test of the sanitizer (QML TestCase) | L0 |

## Interfaces
D-Bus `org.freedesktop.Notifications` 1.2 (spec). Settings keys `notifications.dnd`, `notifications.previews`.
IPC target `notifications`: `toggleCenter()`, `dnd(on)`.

## Degraded behavior
If another server owns the name (e.g. mako), show one warning and run banners-only off.

## Dependencies (verified versions)
Quickshell 0.3.1 `Quickshell.Services.Notifications` (`NotificationServer`, `Notification`, `NotificationAction`; API read
from the installed qmltypes), Qt 6.11.2, `busctl` (ownership probe), `install`/`mkdir`/`chmod` (history file creation).

## Implementation notes (M2)
- Code: `shell/notifications/` (`Notifications.qml` singleton: server, banner queue, history, IPC; `Banners.qml`/`Banner.qml`;
  `NotificationCenter.qml`; `NotificationContent.qml`; pure `Sanitizer.js`, `History.js`).
- Clear model (NotificationCenter.qml): each delegate owns the slide-out (`beginLeave(group, refocus)`: `slide` + `opacity` animations,
  `motion.normal`, `Appearance.duration` so reduced motion shortens it); the end of the animation calls `Notifications.clear(key)` or, for a
  group, `Notifications.clearApp(app)` once (from the header card; the other cards of the group, found through `leavingApp`, only animate).
  `ListView.displaced` is not used: the delegates' `y` is re-laid out by the ListView and the blur regions follow through `motionTick`
  (bumped on every `y`/`slide` change). The list is `panel.gutter` (= close size / 3) wider and taller than the column so the x
  can stick out of the card's corner like the banner's. The keyboard focus after a clear goes to the neighbour found BY KEY (`neighbourKey`
  before the clear, `focusKey` after `forceLayout()`): the list drops a cleared delegate only on its next layout, and that layout took the focus away again.
  `Notifications.clearAll()` stays as the IPC test hook `clearAll()` only; the UI has no global Clear All.
- Banners: one layer-shell window (Overlay layer, no keyboard focus) on the first screen only; input and blur follow the cards.
  Timeout: `expire_timeout` (seconds), -1 = 5 s, 0 and critical = never. Expiry only hides the banner: the entry stays in the Center
  and stays actionable while the sender keeps the notification alive. x / drag-dismiss calls `dismiss()` (sender told "dismissed"),
  the entry stays in the Center as non-actionable. A sender `CloseNotification` removes the entry. Invoking an action or the default
  click clears the entry unless `resident`. Max 5 banners visible; older ones wait in the queue.
- Actions: first 3 non-default actions are buttons, the rest appear after "More" (inline expansion, not a menu).
- Click on a banner/row runs `default` and focuses a window of `desktop-entry` when one is open.
- Notifications column: separate full-screen transparent window (Esc and click outside the cards close, the menu bar strip stays clickable so the
  clock toggles it). Groups by app name, newest first, 3 rows per group then "Show All". Every card, each widget
  tile and the footer controls are separate glass surfaces: each registers itself with the content (`addSurface`) and gets its own blur
  region (`Variants` of `Region`, rectangle in window coordinates, cut to the list viewport for rows, refreshed when the list scrolls or
  changes height). A click outside every registered surface closes; the empty area below the last card is outside the list.
  Opening a menu/popup closes the Center.
  The Center list shows only the DISPLAYED rows: `Notifications.centerModel` (keyed ListModel) holds the first 3 rows of each app
  group (all rows of a group the user expanded with "Show All"; the expansion resets when the Center closes), so collapsed rows
  never get a delegate and the ListView has no sections. The full order lives in two JS arrays (`centerKeys` / `centerApps`:
  grouped by app, newest group first, newest row first inside a group); `syncShown()` reconciles the model with the displayed
  subset and touches it only where that set changed (insert / remove / move by key, a few rows per Notify). Per-row group info
  travels as roles of the rows that need it: `headCount` (> 0 on the first row of a group: draws the header with name, count and
  Clear), `headFirst` (top group, no leading gap), `toggleCount` (> 0 on the row that carries Show All / Show Less); a role is
  written only when its value changed. History insert is O(dropped) (`History.pushNewest`) and
  evicted live notifications are dismissed after the Notify reply (`Qt.callLater`). The Center window is full-screen and keeps its
  size while open (the column slides in once), so a Notify never reconfigures the layer surface; it adds one card and one blur
  region (the region list is rebuilt when a surface registers or the row count changes). Notify round trip on the nested shell,
  loaded machine: median 32-38 ms from 60 to 200 same-app entries (bare gdbus 16-17 ms); before: 44-54 ms at 200. With the Center
  open (history 200, `notifications toggleCenter`): median 35-37 ms against 28-33 ms closed (60 / 40 sends, 2026-10-17).
- Body markup: `Sanitizer.sanitize` keeps only b, i, u and br (balanced); links render as "label (url)" text and are not clickable;
  images are dropped (alt kept); everything else is stripped; 4000 characters max. Images in hints are loaded at <= 256 px.
- DND: `notifications.dnd` in grassfield.json; Quick Settings "Do Not Disturb" tile; moon icon in the menu bar (click turns it off).
  Critical notifications still show; history is kept. `notifications.previews = never` hides bodies (banners and Center).
- History (ADR-0004): `$GRASSFIELD_STATE_HOME/notifications.json` (dev) else `$XDG_STATE_HOME/grassfield/notifications.json`
  (default `~/.local/state/grassfield`). FileView cannot set a mode, so a one-shot `sh -c` Process creates the directory (`mkdir -m 700`)
  and the file (`install -m 600 /dev/null`, then `chmod 600`) before the first read/write; FileView's atomic write (temp + rename) keeps
  the 0600 mode (verified with `stat -c %a`). Max 200 entries, max 7 days (pruned on every arrival and every 30 s), `transient` and
  low-urgency non-resident notifications are not stored, images are not stored, actions are stored as labels and restored non-actionable.
  Writes are debounced 400 ms and blocked until the file was read, so a slow start never wipes the history.
- IPC target `notifications`: `toggleCenter()`, `dnd(on)`, and test hooks `clearAll()`, `invoke(actionId)` (newest live notification; "default" =
  banner click), `status()`, `dismissAll()`.

## Dev / nested testing (private bus)
The nested session shares the owner's D-Bus session bus, where omarchy-shell owns `org.freedesktop.Notifications`. Never take it over:
- In a `GRASSFIELD_DEV=1` session the server is **not created** unless `GRASSFIELD_PRIVATE_BUS=1` (log: "dev session on the shared
  bus; server disabled"). History is still loaded and the Center and DND work.
- `GRASSFIELD_PRIVATE_BUS=1 scripts/dev/shell-run.sh` (or exported before `nested-up.sh`) wraps the shell in `dbus-run-session`; the bus
  address is written to `.dev/bus.address`. Send test notifications with
  `DBUS_SESSION_BUS_ADDRESS=$(cat .dev/bus.address) notify-send ...` and IPC with the same variable
  (`qs -p shell ipc call notifications status`). `shell-run.sh` stops the previous shell by process group so no orphan keeps the old bus.
- The nested output order is WAYLAND-1 (window) then GF-REF: banners, OSD and the Center use the first screen, so capture with
  `scripts/dev/shot.sh <name> WAYLAND-1`.

## Degraded behavior (implemented)
If another process owns the name (probe 1.5 s after start: `busctl --user status` PID differs from Quickshell's), one warning is logged
("owned by another process; banners and history are off"), `serverState` becomes `external` and history writes are blocked. Quickshell
itself logs its own registration warning. Verified on a private bus with a foreign owner.

## Verified (L1, nested, private bus, 2026-10-17)
N1 name owned by qs (`busctl --user status`: PID of qs) · N2/N3 three normal banners gone after 6 s, critical (`-t 1000`) stays ·
N5 `notify-send -A snooze=Snooze` prints `snooze` after `ipc call notifications invoke snooze` · N6 restart restores history, file 0600 ·
N7 Center opens by IPC, Esc (wtype) closes · N8 DND hides banners, moon in bar, critical still shown · N9 unit tests (L0).
Screenshots under `.dev/shots/` (not committed).

## Verified (L1, nested, private bus, 2026-10-19: macOS 26 clear model)
Pointer (`scripts/dev/pointer.sh`) and keyboard (`scripts/dev/keys.sh`) on the nested private bus: no Clear All pill in the footer; hover on a card
shows its x at the top-left corner and, on the group header, the round group x; hover on the group x grows it into "Clear All"; the x of a card clears
only that card (history 8 -> 7) and the column reflows; "Clear All" of the Mail group removed its 4 entries (7 -> 3); Show All then "Show Less" on the header;
Tab reaches a card, then its x (focus ring), Space clears and the focus lands on the next card; Delete on a focused card clears it and focuses the next one.
A2 (`tests/visual/contrast.sh --surfaces desktop,notificationcenter,notificationcenterhover,notificationcenterclear --wallpapers white,black,noise
--transparency 0.25`): 102 cells, 0 failures; card x glyph min 7.1:1, group x glyph min 7.5:1, "Clear All" pill label min 14.9:1 (light and dark).
Not verified: transparency 0.6, Reduce Motion, two outputs, the fr strings on screen (catalog entries only), the pill growth frame by frame
(the nested compositor draws few frames while idle; only the end states were captured).

## Known limitations
- Inline reply depends on Quickshell support; otherwise hidden (not faked). Not offered in M2 (`inlineReplySupported: false`).
- No per-app notification sounds in M2.
- Banner pointer interactions (hover pause, x button, drag dismiss) were NOT verified with a real pointer. The Notifications column
  clear model (hover x on a card, group x growing into Clear All, Show Less, slide-out) was verified with `scripts/dev/pointer.sh` on the
  nested private bus (2026-10-19); the nested compositor draws few frames while idle, so the slide-out can look frozen in a capture taken
  right after the click (it finishes on the next frames; a pointer nudge drives them).
- Banners appear on the first screen only; no per-app settings UI (only the global `notifications.previews`).
- "unlocked" previews behave like "always" until the lock screen (L4) exists.
- Replacing notifications (same id) update the entry and restart the banner timer, but do not re-show a banner that already expired.
- Relative times refresh every 30 s.
- `appIcon` names resolve through the icon theme only; a missing icon shows a bell tile.
