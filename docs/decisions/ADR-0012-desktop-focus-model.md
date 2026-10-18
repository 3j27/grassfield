# ADR-0012: Desktop keyboard focus follows the macOS model
Status: Accepted by owner decision 2026-10-17; spike PASS with three shell-side corrections (see Spike results, 2026-10-18); implemented, nested acceptance (a) to (h) PASS with and without the plugin; amended 2026-10-18: the compositor enforces click-to-focus (see Amendment) · Date: 2026-10-17 · Decider: owner

## Context
The desktop (icons on the wallpaper) is a full-screen layer surface per output; its context menu and rename field
were separate Overlay layer windows with Exclusive keyboard focus, plus a shell-side focus state machine
(`shell/desktop/KeyboardFocus.js`) guessing who gets the keyboard back. Four review cycles found keyboard focus
bugs (keys landing in a terminal, the desktop keeping the keyboard after a window click, keys captured across
outputs, the keyboard ending on no surface). The current state is a safe mode: the desktop never holds the keyboard
except while its menu or rename is active, with Exclusive "catcher" surfaces on other outputs.

macOS (assumption, from memory, no Apple document found): the desktop belongs to Finder, an ordinary app. Clicking the
desktop activates Finder and the keyboard goes to the desktop (arrows, Return to rename, Cmd+Backspace); clicking a
window activates its app. Hover never changes focus. The context menu belongs to Finder; when it closes the keyboard
is back with Finder. A click outside a context menu dismisses it and is swallowed. Clicking elsewhere during a rename
commits it.

## Research (upstream-researcher, 2026-10-17; Hyprland v0.56.2 source read through summaries, Quickshell qmltypes read)
- Hyprland focus is global (one focused surface/window). On a pointer move with no window under the cursor, an
  `on_demand` layer surface gets keyboard focus unless `follow_mouse == 3` or an Exclusive layer holds focus
  (`InputManager::mouseMoveUnified` → `rawSurfaceFocus`). Grassfield uses `follow_mouse = 2`, so **hovering the bare
  desktop would focus an on_demand desktop**: not the macOS behaviour, and dangerous with desktop keyboard actions.
- A click on a window refocuses that window (`processMouseDownNormal` → `refocus`). `rawWindowFocus` is refused while
  an Exclusive layer exists. When a focused layer unmaps, Hyprland calls `refocusLastWindow(monitor)` (same monitor,
  visible window only), otherwise `refocus()` (follows the pointer): the source of the "wrong window" focus on
  multi-output setups.
- Popups of layer surfaces are supported (`get_popup`, Quickshell `PopupWindow` with `anchor.window`); popups of
  Background/Bottom layers are rendered in a last pass above windows. `xdg_popup.grab` starts a keyboard grab; refocus
  after dismissal is not implemented in Hyprland's popup code ("TODO: probably refocus"); whether the dismissing click
  is consumed is unconfirmed.
- Quickshell 0.3.1: `WlrLayershell.keyboardFocus` None/Exclusive/OnDemand map 1:1 to the protocol;
  `PopupWindow.grabFocus`; `HyprlandFocusGrab` (`hyprland_focus_grab_v1`: whitelisted surfaces, pointer input outside
  clears the grab, keyboard moved to a whitelisted surface on start, not restored on finish). No "has keyboard focus"
  property found in qmltypes (Qt's `Window.active` may reflect `wl_keyboard` enter/leave: to verify).

## Decision (proposed)
No shell-side guessing of who gets the keyboard; the compositor decides, and the shell only reacts to its own
surface's focus enter/leave.
1. **Desktop = click-to-focus surface.** Keyboard interactivity `None` until a press on the desktop; the press sets
   `OnDemand` (the pointer is over it, so Hyprland focuses it). When the desktop loses the keyboard (Hyprland focused a
   window after a click elsewhere), it goes back to `None`. Hover alone never focuses it, matching macOS with
   `follow_mouse = 2`.
2. **Context menu = `PopupWindow` anchored to the desktop surface** with a keyboard grab (`grabFocus`, or a
   `HyprlandFocusGrab` whitelisting the popup and the desktop surface). On dismissal the desktop surface is focused
   again (it is whitelisted / under the pointer); a click outside dismisses and is swallowed.
3. **Rename = a text field inside the desktop surface** (the surface already holds the keyboard after the click and
   the menu). Click elsewhere commits (macOS); Esc cancels.
4. Remove the Overlay menu/rename windows, the catchers and `KeyboardFocus.js` state beyond "desktop focused or not".
   Desktop keyboard navigation (arrows, Return, Ctrl+Backspace, Space → Glance) comes back, active only while the
   desktop surface holds the keyboard.

## Evidence required before implementation (nested spike)
1. `follow_mouse = 2`: with the desktop at `None`, hovering the bare desktop and typing goes to the previously focused
   window; after a press with `OnDemand`, the desktop receives keys.
2. Click a window over the desktop, then the desktop: focus flips both ways; the desktop sees keyboard leave/enter
   (`Window.active` or an equivalent signal).
3. `PopupWindow` with `grabFocus` (and `HyprlandFocusGrab` variant): it receives keys; after Esc / item / click
   outside, where does focus land? Is the outside click delivered?
4. Click outside on a window on the second output: the grab clears; no key reaches the menu afterwards.
5. A focused desktop surface on output A, click a window on output B: the window gets focus.
6. The popup draws above windows.
If (3) shows focus landing nowhere after dismissal, the desktop re-takes it explicitly on the popup's `visibleChanged`
(the only shell-side step), and the ADR records it.

## Spike results (2026-10-18, nested Hyprland 0.56.2, Quickshell 0.3.1) — VERIFIED
Setup: a standalone QML config (`.dev/spike/qs/shell.qml`, not committed: a full-screen Bottom-layer `PanelWindow`, keyboard
`None` until a press, `Window.active` / `activeFocus` / key logging, a `PopupWindow` anchored to it in two variants) run with
`qs -p` on the nested socket; two probe foot windows (`scripts/dev/isolated.sh foot`, each key appended to `.dev/probes/<name>.txt`);
input only through `scripts/dev/keys.sh` / `pointer.sh`. Two outputs (WAYLAND-1, GF-REF), `follow_mouse = 2`. The whole suite
(`.dev/spike/suite.sh`) was run twice with identical results: with the plugin loaded and with `nested-up.sh --no-plugin`
(logs: `.dev/spike/suite-plugin.txt`, `suite-noplugin.txt`, `spike-plugin.log`, `spike-noplugin.log`; the plugin makes no difference).

| # | Experiment | Result |
|---|---|---|
| 1a | desktop `None`, hover, type | keys reach the previously focused foot (`[h][o][v]`), 0 desktop keys. PASS |
| 1b | switch to `OnDemand` on a press, no further pointer motion | the keyboard is NOT given: typing still goes to foot. Hyprland re-evaluates only on the next pointer motion (or press) over the bare desktop. After one more motion the desktop has it (`Window.active=true`, `activeFocus=true` within ms). **Correction 1** below |
| 1c | `OnDemand` permanently, hover | hovering focuses the desktop at once (also at map time): confirms the research; a permanent `OnDemand` is excluded |
| 1d | desktop `None` after having the keyboard (`want=false`) | Hyprland gives the keyboard back to its last window (foot got the next keys). The desktop sees it: `Window.active=false`, `activeFocus=false` |
| 2 | desktop holds the keyboard, click a foot | a window that is NOT Hyprland's last active window gets the keyboard (focus flips, desktop logs `Window.active=false`); the desktop gets it back by a press (+ correction 1). **If the clicked window is the last active window, Hyprland does nothing: the desktop keeps the keyboard, also after a second click** (typing goes to the desktop, `desktop keys: 3`). **Correction 2** below |
| 3 grab | `PopupWindow{grabFocus:true}` | receives keys (`POPUP KEY`, arrows/Esc usable); the desktop gets `activeFocus=false` while its `Window.active` stays true (use `activeFocus`, not `Window.active`, while a popup is open). Esc and an item click: the popup unmaps, the keyboard is back on the desktop surface 20-80 ms later (`activeFocus=true`), typing goes to the desktop. Outside click on a foot: the popup closes, the click is SWALLOWED (foot gets nothing, `activewindow` unchanged), the keyboard goes back to the desktop. Same on the other output (experiment 4). The popup draws above windows: `.dev/shots/spike-popup-above-window.png`. PASS |
| 3 hfg | `HyprlandFocusGrab{windows:[popup, desktop]}`, popup without `grabFocus` | the popup does NOT get keys (the grab moves the keyboard to the desktop surface); an outside click clears the grab and focuses the clicked window (not swallowed). Not chosen |
| 4 | popup open, click a foot on the other output | grab cleared, popup unmapped, click swallowed, keyboard back on the desktop of output A (typing: `desktop keys: 2`, B got nothing); the popup receives no key afterwards. PASS |
| 5 | desktop focused on A, click a foot on output B (not the last window) | foot B gets the keyboard (`[e][5]`). PASS |
| 3b | outside click on a foot that IS the last active window, then click it again | **stuck**: the desktop (parent of the dismissed popup) has the keyboard while the pointer is over foot; the next click does not give it to foot (Correction 2 case) |
| 6 | plugin loaded vs `--no-plugin` | identical results for every row |

### Corrections found by the spike (the only shell-side steps)
1. **Kick after a press** (1b). After a press the desktop sets `OnDemand` and maps a transient 1x1 transparent Background layer
   surface (`kicker`, keyboard `None`) for `Tokens.desktopIconFocusKickMs`: mapping and unmapping a layer surface makes Hyprland re-run
   its pointer focus logic, which grants the keyboard to the `OnDemand` desktop under the pointer within about 60-120 ms, without any pointer
   motion. Tried and rejected as kicks: a 1 px margin change, an exclusive zone change (no effect); a layer flip Bottom/Background works but reorders
   against the widgets surface. If the keyboard is not granted within `desktopIconFocusArmMs` (pointer over a window), the desktop goes back to `None`.
2. **Pointer leave drops the keyboard** (2). While the desktop holds the keyboard and the pointer leaves its surface (onto a window, the other output,
   the Dock, the menu bar), the desktop goes back to `None` and Hyprland returns the keyboard to its last window, so the next click on that window
   works even when it is the last active one. Deviation from macOS (keys follow the clicked app, not the pointer): typing right after moving the pointer
   onto a window without clicking goes to that window. While a context menu is open the pointer leave (onto the popup) is ignored.
3. **Outside-dismissed menu** (3b). The keyboard goes back to the desktop even when the pointer is over a window, and the stuck case above follows.
   After a dismissal by an outside click the desktop therefore drops to `None` and re-arms (press-like, with the kick): the keyboard comes back to the desktop only if
   Hyprland finds the pointer on the bare desktop. After Esc or an item the keyboard is simply back on the desktop (the pointer is on the menu, over the desktop).

### Mechanism chosen
The ADR decision above, with `PopupWindow.grabFocus` (not `HyprlandFocusGrab`) and corrections 1-3. The fallback "the desktop re-takes the keyboard explicitly on popup close"
was NOT needed: the keyboard returns to the parent by itself after Esc / item / outside click.

### Residual limits found
- If the pointer rests on a window area covered by the open menu when it closes by Esc or an item, the desktop has the keyboard under a window; one pointer move away
  from the desktop and back, or a click on another window, fixes it (a click on the last active window alone does not).
- Pointer leave to any other surface (including the widgets layer) drops the desktop keyboard (see correction 2).
- Keys sent during the ~20-80 ms between the menu closing and Hyprland returning the keyboard are dropped by the closing popup (measured, see desktop.md).

### Implementation acceptance (2026-10-18, nested, `.dev/spike/acc.sh`; logs `.dev/spike/acc-plugin.txt`, `acc-noplugin.txt`) — VERIFIED
(a) hover + type: foot gets the keys, 0 desktop keys. (b) click, Down, Down, Return, `zz`, Return: the second icon renamed in `.dev/desktop-sandbox`, foot got nothing.
(c) click foot, type: foot. (d) right-click, Esc, Return, Esc, `dd`: desktop keys, foot nothing; then a click on foot: foot gets the keys. (e) menu open, click foot: menu closed, click swallowed,
files unchanged, typing goes to foot (last window). (f) menu open + click foot on the other output: closed, no stale key; rename active + click foot on the other output: committed, keys to that foot.
(g) Space opens Glance, Esc closes it. (h) 10x menu/Esc/type: 0 misdelivered; typed 50 ms after the Esc 10/10, typed at once 2 to 8 of 10 (rest dropped). Ctrl+Backspace on a sandbox file moved it to `.dev/apps-home/data/Trash`; the owner's `~/.local/share/Trash/info` mtime unchanged.
The keyboard grant check uses `Window.active`, not `activeFocus` (found during acceptance: `forceActiveFocus` sets activeFocus on an inactive window).

## Amendment (2026-10-18, integrator decision on the owner's behalf): the compositor enforces click-to-focus
Review of 354cf71: the shell-side corrections cannot make the model safe. Hyprland ignores a click on its focused window
while the desktop holds the keyboard (desktop keyboard actions then ran while the user believed the terminal had focus),
the kicker grants the keyboard only after 60-180 ms (keys typed right after the click went to the previous window), and
the pointer-leave drop sends keys to a window the user did not click (hovering the Dock or the menu bar, a swallowed
outside click).

Decision: grassfield-compositor enforces the policy on pointer button presses (capability `desktop-focus`, ADR-0007):
a press on a window while the desktop holds the keyboard gives that window the keyboard; a left press on the desktop gives
it the keyboard on its `on_demand` commit, with no motion; nothing else moves the keyboard (no hover focus; Dock, menu bar,
widgets and popups keep it on the desktop, as Finder stays active on macOS; the menu's popup grab is untouched).
- **With the capability** the shell removes the kicker and the pointer-leave drop and may enable the file-changing
  desktop keys (`IconsView.fileKeyActions`).
- **Without it** (no plugin, ABI mismatch, or withdrawn at unload by an empty capabilities event) the shell keeps the
  kicker and the pointer-leave drop, and file-changing desktop keys stay off.
Exact contract: `docs/specs/desktop.md` "Compositor focus policy". Evidence: `tests/compositor/desktop_focus.sh` 21/21
PASS with the plugin; `baseline` (plugin unloaded) reproduces the three defects. Spike corrections 1 and 2 above become
fallbacks for the plugin-less case; correction 3 is not needed with the plugin.

### Policy v2 (2026-10-18, capability `desktop-focus-v2`)
The shell integration review found that the first policy misread a click made without pointer motion right after the
context menu closed (Hyprland's pointer focus was still the closed popup's surface; the keys stayed on the desktop, and a
sandbox file was trashed by Ctrl+Backspace); the R13 review of 5706cbd found two minors. The plugin now (a) takes the
press target from under the cursor (Hyprland's pointer focus order) when the pointer focus is missing or stale, (b) drops a
pending desktop grant on any other focus change (keyboard focus, window activation, window mapping, workspace switch),
(c) grants a window the keyboard through Hyprland's `fullWindowFocus` only (no forced surface focus that could bypass
`no_focus` or a modal child). It advertises `desktop-focus-v2` together with `desktop-focus`; the shell enables its
file-changing desktop keys only with `desktop-focus-v2` (shell main 23caeab). Evidence: `tests/compositor/desktop_focus.sh`
26/26 with cases 7 (slow commit) and 8 (click without motion). The previous plugin build e066a19 fails three of these
cases, not only one per mode: `stale` fails case 8 (`desktopA=pf`: after menu, pointer onto the foot, Esc, the click left
the keys on the desktop), and `race` passes only 1 of its 4 checks: case 7a fails (`desktopA=ka`: the late `on_demand`
commit took the keyboard from the window a focus dispatch had just focused), case 7b fails (`desktopA=kn`: it took it
from a window that had just mapped), the plugin-log check fails (that build cancels no pending grant), only the control
7c passes (run `.dev/desktop-focus/run-20261018-135258-race`, recorded in
`docs/specs/compositor.md` FR30; the plugin build e066a19 loaded with `nested-up.sh --no-plugin` + `scripts/nestctl plugin
load`).

## Consequences
- The safe mode and its catchers are temporary; this design replaces them after a spike PASS and a review.
- Grassfield depends on `hyprland_focus_grab_v1` / xdg_popup grab semantics of Hyprland; re-verify on Hyprland
  updates (docs/compat.md).
