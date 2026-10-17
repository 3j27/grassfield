# ADR-0012: Desktop keyboard focus follows the macOS model
Status: Proposed (owner decision 2026-10-17; mechanism to be confirmed by a nested spike) · Date: 2026-10-17 · Decider: owner

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

## Consequences
- The safe mode and its catchers are temporary; this design replaces them after a spike PASS and a review.
- Grassfield depends on `hyprland_focus_grab_v1` / xdg_popup grab semantics of Hyprland; re-verify on Hyprland
  updates (docs/compat.md).
