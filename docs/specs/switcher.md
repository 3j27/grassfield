# Spec: app switcher (`shell/switcher/`)

Closes F1 gap 19 (`docs/testing/f1-reference-gaps.md`): the macOS Cmd+Tab model, with SUPER as the Command equivalent
(ADR-0002).

## Behaviour

- **SW1** SUPER+TAB opens a session on the next app, SUPER+SHIFT+TAB on the least recently used one. Inside a session Tab
  (and its key repeat), Shift+Tab, Right and Left move the selection (wrapping); Q quits the selected app (asks every
  window to close through the Dock's Quit path, never a kill); H hides it (Compositor.hide, as the Dock); Esc cancels.
- **SW2** Apps are the Dock's identity (`DockModel.merge` with no pins: app id resolved to a desktop entry, case
  insensitive), one tile per app, **most recently used first**. The first selection is the second app (the previous one)
  when the most recent app is the focused one; with nothing focused (empty desktop, only the shell's surfaces) it is the
  most recent app itself, so that Tab never skips it. An app's recency is its newest window's focus stamp
  (`Compositor.recency`, set from `ToplevelManager.activeToplevel` changes; windows never focused keep window-list order).
  Minimized and hidden apps are listed. Windows without an app id are skipped. The shell's own surfaces are layer-shell
  surfaces, not toplevels, so they never appear.
- **SW3** The order is frozen when the session starts (apps that quit leave, new ones go last).
- **SW4** **Quick switch**: a press and release of SUPER+TAB shorter than `switcher.showDelayMs` (150 ms) activates the
  previous app without drawing the panel. The panel is shown after that delay with the modifier still held, or at a second
  Tab/arrow.
- **SW5** Releasing SUPER activates the selection: the app's most recent window not minimized (else the most recent one)
  goes through `Compositor.activate` (un-minimizes, brings a hidden window back, then the foreign-toplevel activate), and
  the app's other hidden windows come back with it (macOS: activating a hidden app unhides all its windows). That is
  Grassfield's focus path, so Hyprland switches to the window's Space and, with Stages, brings the window's stage forward
  (ST10: a user-reason focus). Hyprland refuses to focus a window while an exclusive layer surface exists
  (`FocusState.cpp`), so the activation runs when the compositor reports the switcher's surface unmapped (`closelayer`
  event, `Compositor.layerClosed`); `switcher.layerWaitMs` (250 ms) is only the fallback when no such event arrives.
- **SW6** Pointer: moving over a tile selects it (not when the panel appears under a still pointer), a click activates it, a
  click outside cancels.
- **SW7** Starting the switcher closes Search, Overview, Apps and any popup, and opening one of them cancels the switcher
  (`ExclusiveSurfaces` in shell.qml; the controller exposes `open`, true for a whole session). The session lock cancels it
  and it does not start while the session is locked (`Switcher.locked`).
- **SW8** SUPER+` activates the next window of the focused app (`windows cycleApp`; minimized windows are skipped). The key
  is bound by keycode (`code:49`, the key above Tab: grave on a US layout, a different symbol on AZERTY), so it works on
  every layout; Settings > Keyboard shows it as "Key above Tab" (fr: "Touche au-dessus de Tab"). ALT+TAB keeps cycling
  windows of the active stage (ST10).
- **SW9** Settings > Keyboard lists the shortcuts: the binds are literal `bind("KEYS", "Description", ...)` lines that
  `apps/settings/qml/Bindings.js` parses, with their descriptions and fr strings.

## Key handling (decision, verified on Hyprland 0.56.2 Lua and in nested)

**No key map (submap).** The first design entered a `"switcher"` submap on SUPER+TAB and bound the release of Super_L/Super_R
inside it. That cannot work. Hyprland stores, for every key press, the key map active when it went down
(`SPressedKeyWithMods.submapAtPress`, `KeybindManager.cpp` `onKeyEvent`, commit efb5099 = the installed headers) and on
release only considers binds of that map (`handleKeybinds`: `k->submap.name != key.submapAtPress.name`). SUPER goes down in
the default map, so a release bind inside "switcher" never fires: the panel stayed up, the map stayed active (SUPER+Q,
SPACE, RETURN, CTRL+arrows, volume keys stopped working, the first Esc was swallowed). Leaving a global mode must never
depend on an event that can fail to arrive, so the redesign has no global mode at all. Alternatives weighed: (b) an
`hl.timer` polling `hl.is_key_down` is polling inside the compositor config and still needs the shell to take the keys;
(c) a submap with a reset on every exit path keeps a mode that can get stuck (crash, lock, shell restart).

How it works (`config/hypr/grassfield/bindings.lua`, `Switcher.qml`, `SwitcherWindow.qml`):

- `SUPER + TAB` / `SUPER + SHIFT + TAB` (repeating binds in the default map) run `qs ipc call switcher next|previous <id>`.
  `<id>` is a hold id: Lua increments it when SUPER goes down for a new hold (it starts from `os.time()`, so a config
  reload never reuses an id the shell has seen).
- The session holds an **exclusive-keyboard layer surface** (`SwitcherWindow`, namespace `grassfield-switcher`, on the
  focused window's output) from the first request on: transparent for `showDelayMs` (quick switch), then the panel. The
  surface has the keyboard, so it receives Esc, arrows and Return, and it sees the **Super release itself**
  (`Keys.onReleased`: Key_Super_L / Key_Super_R / Key_Meta). Hyprland still runs binds first, so SUPER+TAB (and its
  repeats) never reach it.
- Second path, **the release bind in the default map** (`SUPER + Super_L`, `SUPER + Super_R`, `Super_L`, `Super_R`,
  `release`, `non_consuming`, `transparent`) sends `qs ipc call switcher release <id>` once per hold. It covers a release
  that happens before the surface has the keyboard (a quick tap: the two `qs ipc` processes take ~100-250 ms). `transparent`
  is required: after SUPER+TAB fired, `shadowKeybinds` disables every bind whose key is still down, and only `transparent`
  binds are exempt (found in nested: without it the bind never fired).
- The shell orders the requests by hold id (`Switcher.step/release`): a `release` that arrives before its `next` marks the
  hold ended, and the late `next` switches at once (no surface, no panel); a late key repeat of an ended hold is ignored.
  Both release paths can fire for one hold; the second finds an idle session and does nothing.
- `SUPER + Q` and `SUPER + H` keep their normal meaning (close window, hide app) and act on the selected app instead while
  the switcher surface is mapped (`hl.get_layers({namespace = "grassfield-switcher"})`, `mapped`), decided by Lua at key
  time, so no state can go stale.
- Whatever ends a session (release, Esc, click outside, a tile click, another full-attention surface, the session lock,
  every app gone) sets the session idle, which unmaps the surface and with it the grab; nothing is left in the compositor.
  A shell restart or crash drops the surface the same way. There is no submap to reset, so volume and brightness keys
  (`locked` binds) and every shortcut work throughout, including on the lock screen.

Limits:
- Keys typed in the first ~250 ms after SUPER+TAB (before the surface has the keyboard) still go to the focused app; Tab
  repeats and Q/H are binds and are not affected, Esc and arrows are.
- If both release paths were lost (the surface never got the keyboard and the config's bind did not fire), the session
  ends with Esc or a click.
- Test injection: `tests/tools/vkbd` (a `zwp_virtual_keyboard_v1` client with its own us keymap, modifier state tracked with
  xkbcommon) sends real key events, so the binds, the grab and the release are exercised for real
  (`tests/shell/switcher/nested.sh hold|quick|second|keys`). It refuses anything but the verified nested socket. Two vkbd
  processes at once interfere (each sends its own modifier state): send one key sequence per invocation.

## Surface

One full-screen transparent overlay layer per output (namespace `grassfield-switcher`), mapped on the focused output only
while a session runs (exclusive keyboard); panel drawn after the show delay. Material per master-prompt 5.5: frosted tint
from the compositor blur region (`BackgroundEffect`; layer rule fallback in `windows.lua`), never faked. Tokens
`switcher.*`: icon 104, pitch 134, selection square 123 (radius 33), panel radius 60 and padding 22, the selection concentric
with the panel's corner (macOS 27's App Switcher measured, ADR-0039 step 13). Apps wrap into rows when the output
is narrower than the row (`SwitcherModel.grid`). The selected app's name sits under the row, centred on the selected
column. The selection square carries the shared focus ring (visible keyboard focus; ADR-0039 step 7) on the neutral selection of an
item on glass (`material.selectionOpacity`, step 12). Fade and scale with `motion.fast`; Reduce
Motion: fade only.

Accessibility: panel `Accessible.List` "Application Switcher", each tile a `Button` named after the app, `focused` on the
selection. Contrast: the app name is primary text on material (role `switcher app name on material`).

## Files

`SwitcherModel.js` (pure: MRU order, refresh, reducer, grid; tests `tests/unit/tst_switchermodel.qml`), `Switcher.qml`
(controller, IPC target `switcher`: next/previous `<id>`, left, right, release `<id>`, cancel, quit, hide, status),
`SwitcherWindow.qml` (surface and panel). `platform/Compositor.qml` adds `layerClosed`, `isHidden` and the `windows cycleApp`
handler.

## Verification (nested, Hyprland 0.56.2)

With `tests/shell/switcher/nested.sh` (real keys through the virtual keyboard): hold (panel, then activation), quick tap
(previous app, no panel), second Tab, Esc cancel, click outside cancel, Q on the selected app, hidden app brought back
with all its windows, SUPER+Q and SUPER+` afterwards. Not verified: real hardware (L2), the session lock (never typed
into a nested lock screen).

## Limits

- Quit asks windows to close; an app with an unsaved-changes dialog stays listed (as macOS).
- Hidden apps are listed; activating one brings all its windows back to the focused Space.
- Recency starts when the shell starts: apps never focused since then sort by window list order.
- The release paths need the session config (`bindings.lua`); without it the panel's own keys (Esc, arrows, Return, click)
  and the IPC target still work.
