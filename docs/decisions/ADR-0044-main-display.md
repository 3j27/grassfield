# ADR-0044: The main display, and the wallpaper per display
Status: Proposed (applied provisionally, owner rule of 2026-10-28: the closest to macOS 27, no technical step for the end
user) · Date: 2026-11-04 · Decider: owner (revisit), integrator (merge) · Number: 0044 (0043 is the public installation script)

## Context

The owner installed rc1-22 on a second machine with several displays and found that "there is no way to choose which
display is the main one" and "no way to set the wallpaper per display".

What the code did on 2026-11-04 (main e8e6856b):
- Menu bar: one per output (`MenuBar.qml`, a `Variants` over `Quickshell.screens`). Unchanged by this ADR (macOS 27 has a
  menu bar on every display).
- Dock: one window per output, one output has the Dock (`Geometry.dockScreen`); it started on the *focused* output at
  login (a race on a second machine) and then followed the pointer's dwell on another output's Dock edge. No setting.
- Desktop icons: the *first* of `Quickshell.screens`. Notification banners: the focused output (`Compositor.activeScreenName`).
  Nothing let the user say which display is "the" display.
- Wallpaper: already per display since ADR-0016 section 8 (`wallpaper.outputs`, identity serial and model else connector; the
  shell resolves `WallpaperConfig.resolve(Settings.wallpaper, output)` per output; Settings > Wallpaper has a "Display" row
  with "All Displays" and each display, shown with more than one output). The row was the first of the options group beside
  the preview, easy to miss; this ADR makes no storage change for it.

## Decision

### D-1 The main display holds the Dock, the desktop icons and the notification banners
macOS: Displays > "Use as" > Main display. The Dock starts on it and moves to it when the main display changes; the pointer
reaching another output's Dock edge still moves the Dock there (macOS does the same with the Dock at the bottom). The desktop
icons and the banners are on it. Menu bars stay on every display. New windows follow the compositor's focus as before
(Hyprland places a window on the focused monitor; this ADR does not change window placement).

### D-2 Storage: `displays.main`, one remembered choice per set of connected displays
A new key of grassfield.json (contract version 1, additive; schema, generated `SettingsContract.js`, defaults):
`displays.main` is a list, newest first, at most 16, of `{set: [<display key>...sorted], main: <display key in set>}`.
- A display key is its identity, `DisplayRole.identity` (`ui/Grassfield/Ui/DisplayRole.js`): `s:<make>|<model>|<serial>` when it
  has a serial, else `m:<make>|<model>|<connector>` (two identical monitors without a serial stay apart), else `n:<connector>`
  for an output with no EDID at all. A connector name alone is never the key of a real monitor. The same panel on another
  port is the same display *when it reports a serial*. The data is Hyprland's `monitors` answer (`make`, `model`, `serial`),
  which the shell already reads (`platform/Displays.qml` `described`) and publishes to Settings in the Displays state file:
  Qt's `QScreen` and Quickshell's `ShellScreen` are not used, because Qt 6.12's `QWaylandScreen` has no serial (it is always
  empty) and no make. A monitor with an EDID without a serial moves its key with its port.
- One entry per set: the choice comes back when the same displays are connected again (laptop alone, laptop at the desk).
- The Settings app writes it through `ConfigStore.set` (the existing store; the contract validates it). The shell reads it
  through `SettingsStore` and resolves it in `shell/services/MainDisplay.qml` from `Quickshell.screens` joined to Hyprland's
  answer, live. `MainDisplay.ready` is false until every output is described (or `Tokens.dockSettleTimeout` has passed), and
  `screenName` is "" until then: the Dock waits for it and for the settings before it latches, so it never takes a fallback
  output that the stored choice would overrule. Changes of the outputs (a hot-plug is a burst) take effect after
  `Tokens.motionSlow`. The dev override `GRASSFIELD_DESKTOP_SCREEN` is read here, once, and is the main display while that
  output exists: the Dock, the desktop icons (`DesktopSurfaces.iconsScreen`) and the banners all read `MainDisplay.screenName`.

### D-3 Resolution and fallback (`DisplayRole.resolve`)
1. The choice made for exactly this set of connected displays.
2. Else the newest choice, for another set, whose display is connected: plugging a display in or out does not move the
   role while the main display is still there.
3. Else (the main display was unplugged, or never chosen): the built-in panel (connector eDP, LVDS or DSI), else the
   first output.
A bad stored list reads as no choice (the entries that are fine are kept; nothing is rewritten).

### D-4 Settings > Displays: "Use as"
With more than one display, each display's group has a "Use as" pop-up: "Main display" or "Extended display". The main
display offers only "Main display" (it stays main until another display is made main, as in macOS); choosing "Main display"
on another display makes it main. Arrange… draws the main display's tile with the solid menu bar. Mirroring is not offered
(NOT in this step: Hyprland can mirror, the Arrange sheet and the trial lines do not model it).

### D-5 Wallpaper per display
No storage change: `wallpaper.outputs` keeps its shape and the top-level keys remain "All Displays", so an existing single
wallpaper setting needs no migration (a file with no `outputs` shows the same wallpaper on every display until the user
picks per display). The Display pop-up moves to the top of the pane, above the preview, with a line saying whether the
display follows All Displays. Entry point for other surfaces (the desktop's Change Wallpaper…): the Settings command line
`grassfield-settings --section=wallpaper --display=<output name>`, which a second launch hands to the running instance as
the D-Bus `Open("wallpaper@<output name>", token)`; the pane opens on that display (an unknown output is ignored, the pane
then shows All Displays).

Known limit (not changed here): the wallpaper's display identity (`WallpaperConfig.displayKey`) reads Qt's screens, whose serial is
empty under Wayland, so a per-display wallpaper is in effect keyed by the connector name; moving a monitor to another port loses
its wallpaper override until it is set again. Moving it to Hyprland's data is a follow-up.

### D-6 XWayland primary
`xrandr --output <main> --primary` would need `xorg-xrandr` (not installed here, not a Grassfield dependency): not done,
NOT VERIFIED, no new dependency. GTK/Qt/Wayland-native apps are unaffected.

## Consequences
- Contract: `displays.main` (additive). Readers: shell (`MainDisplay`), Settings (Displays). Tests: `tests/unit/tst_displayrole.qml`.
- The dev override `GRASSFIELD_DESKTOP_SCREEN` is folded into `MainDisplay`: the one source for the Dock, the icons and the banners.
- The banners no longer follow the focused output: they stay on the main display (macOS).
