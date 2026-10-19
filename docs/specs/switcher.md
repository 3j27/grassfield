# Spec: app switcher (`shell/switcher/`)

Closes F1 gap 19 (`docs/testing/f1-reference-gaps.md`): the macOS Cmd+Tab model, with SUPER as the Command equivalent
(ADR-0002).

## Behaviour

- **SW1** SUPER+TAB opens a session on the next app, SUPER+SHIFT+TAB on the least recently used one. Inside a session Tab,
  Shift+Tab, Right and Left move the selection (wrapping); Q quits the selected app (asks every window to close through
  the Dock's Quit path, never a kill); H hides it (Compositor.hide, as the Dock); Esc cancels.
- **SW2** Apps are the Dock's identity (`DockModel.merge` with no pins: app id resolved to a desktop entry, case
  insensitive), one tile per app, **most recently used first**. The first selection is the second app (the previous one).
  An app's recency is its newest window's focus stamp (`Compositor.recency`, set from `ToplevelManager.activeToplevel`
  changes; windows never focused keep window-list order). Minimized and hidden apps are listed. Windows without an app id
  are skipped. The shell's own surfaces are layer-shell surfaces, not toplevels, so they never appear.
- **SW3** The order is frozen when the session starts (apps that quit leave, new ones go last).
- **SW4** **Quick switch**: a press and release of SUPER+TAB shorter than `switcher.showDelayMs` (150 ms) activates the
  previous app without drawing the panel. The panel is shown after that delay with the modifier still held, or at a second
  Tab/arrow.
- **SW5** Releasing SUPER activates the selection: the app's most recent window not minimized (else the most recent one)
  goes through `Compositor.activate` (un-minimizes, brings a hidden window back, then the foreign-toplevel activate). That
  is Grassfield's focus path, so Hyprland switches to the window's Space and, with Stages, brings the window's stage
  forward (ST10: a user-reason focus). Stages needs no request of its own. With the panel up, the activation waits
  `switcher.commitDelayMs` so the panel's keyboard grab is released first.
- **SW6** Pointer: moving over a tile selects it (not when the panel appears under a still pointer), a click activates it, a
  click outside cancels.
- **SW7** Opening the switcher closes Search, Overview, Apps and any popup.
- **SW8** SUPER+` activates the next window of the focused app (`windows cycleApp`; minimized windows are skipped). ALT+TAB
  keeps cycling windows of the active stage (ST10).

## Key handling (verified on Hyprland 0.56.2, Lua)

A client cannot see a modifier release before it has the keyboard, and a quick press ends before it does, so the compositor
config owns the keys (`config/hypr/grassfield/bindings.lua`):

- `SUPER + TAB` / `SUPER + SHIFT + TAB`: Lua function that dispatches `hl.dsp.submap("switcher")` then
  `qs ipc call switcher next|previous`. Because the key map is entered by the same press, the release is always seen.
- `hl.define_submap("switcher", ...)` binds, with SUPER held: TAB, SHIFT+TAB, LEFT, RIGHT, Q, H, ESCAPE (also without
  SUPER), and the release binds of `Super_L` / `Super_R` (`release = true`). Release and Esc reset the key map and send
  `release` / `cancel`. The binds win over the panel's exclusive keyboard grab, so SUPER+Q inside the switcher quits the
  selected app instead of closing the focused window.
- The shell watches the `submap` raw event (`Compositor.submap`). If the key map was left and no `release` request arrives
  within `switcher.backstopMs`, it commits by itself; a `next` request that arrives after the key map was already left (the
  two `qs ipc` processes race) commits at once (quick switch).
- With no compositor config (no key map) the panel still takes Esc, arrows, Tab and Return from its keyboard grab.
- wtype's `-M logo` only sets the modifier mask and never sends a Super key event; test the release with
  `wtype -P Super_L -k Tab -p Super_L` (see Tests).

## Surface

One full-screen transparent overlay layer per output (namespace `grassfield-switcher`, exclusive keyboard while shown),
panel mapped on the focused output only. Material per master-prompt 5.5: frosted tint from the compositor blur region
(`BackgroundEffect`; layer rule fallback in `windows.lua`), never faked. Tokens `switcher.*`: icon 104, pitch 134,
selection square 123 (radius 26), panel radius 30. Apps wrap into rows when the output is narrower than the row
(`SwitcherModel.grid`). The selected app's name sits under the row, centred on the selected column. The selection square has
an accent border (visible keyboard focus). Fade and scale with `motion.fast`; Reduce Motion: fade only.

Accessibility: panel `Accessible.List` "Application Switcher", each tile a `Button` named after the app, `focused` on the
selection. Contrast: the app name is primary text on material (role `switcher app name on material`).

## Files

`SwitcherModel.js` (pure: MRU order, refresh, reducer, grid; tests `tests/unit/tst_switchermodel.qml`), `Switcher.qml`
(controller, IPC target `switcher`: next, previous, left, right, release, cancel, quit, hide, status),
`SwitcherWindow.qml` (panel). `platform/Compositor.qml` adds `submap` and the `windows cycleApp` handler.

## Limits

- Quit asks windows to close; an app with an unsaved-changes dialog stays listed (as macOS).
- Hidden apps are listed; activating one brings its windows back to the focused Space.
- Recency starts when the shell starts: apps never focused since then sort by window list order.
- The release path needs the session config (key map); without it only the panel's own keys and the IPC target work.
