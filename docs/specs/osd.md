# OSD spec · shell-engineer · M2

## macOS reference behavior (described in words)
- Older macOS shows a centered-bottom rounded square (about 200 pt) with a large icon and a 16-segment bar.
- Recent macOS (26/27 style) shows a compact pill under the menu bar at the top-right: small icon on the left, a thin level bar
  filling the rest, on the standard material; it appears on a volume or brightness change and fades after about 1.5 s.

## Decision
Grassfield implements the **macOS 26/27 style**: a compact top-right pill under the menu bar, icon plus continuous level bar (no
segments). Reasons: it matches the rest of the M2 notification surfaces (same corner, same material) and needs no extra layout
for tall icons. The centered-bottom square is not implemented.

## Purpose and non-goals
Feedback for output volume/mute and display brightness changes, whoever causes them. Non-goals: microphone, input-source popup,
media-key bindings (the session config binds keys to the IPC targets below), slider interaction (the pill never takes input).

## Functional requirements
1. O1 The OSD shows on a change of the default sink volume or mute (Quickshell Pipewire through `qs.services.Audio`), and on a change
   of the backlight (`/sys/class/backlight/<first>/actual_brightness`, watched by FileView plus a 1.5 s poll fallback).
2. O2 Layout: pill `osd.width` x `osd.height` (220 x 44) at `menubarHeight + osd.gap` from the top, right aligned, material
   background with compositor blur, `volume-*`/`sun` icon, bar `osd.barHeight` (6) using `text` over a `fill` track; muted shows an
   empty bar and the `volume-mute` icon.
3. O3 It fades in/out (`motion.normal`, capped by Reduce Motion) and hides `osd.hideDelay` (1.6 s) after the last change; a new change
   restarts the timer. Never takes input (empty input region).
4. O4 Changes during the first 1.5 s after start and after a default-sink switch are ignored (initial reads are not user actions).
5. O5 Without a backlight device, brightness never shows and the brightness IPC does nothing (logged).
6. O6 Real changes by IPC (for key bindings): `volume up|down|mute` runs `wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+` /
   `5%-` / `set-mute ... toggle`, `brightness up|down` runs `brightnessctl -d <dev> set 5%+|-`; the OSD is shown afterwards even if
   the value did not change (limits).
7. O7 In a `GRASSFIELD_DEV=1` session brightness is never changed (the nested shell controls the owner's hardware): the IPC only logs and
   shows the current level. Volume changes are real (5 % steps; tests restore the value).

8. O8 Keyboard backlight HUD (macOS: the keyboard brightness HUD; REQ-OSD-NG-d1a, master prompt 5.2 "volume/brightness/keyboard OSD"; owner decision 2026-10-23, follow macOS): the same pill as volume and brightness (`kind` `keyboard`, the `keyboard` glyph and the continuous bar), shown on a change of `/sys/class/leds/*kbd_backlight/brightness` (`Brightness.kbdValue`, watched by FileView; the first value read after start is not a change; O4 applies) and by the IPC target `keyboard up|down` (a step is 1/16 of the range, the 16 notches of the macOS keys, at least one device step; `brightnessctl -d <device> set <n>` through `Brightness.setKbdLevel`, which in a `GRASSFIELD_DEV=1` session only logs, so the OSD then shows the current level, as O7). Without a keyboard backlight device the IPC logs "no keyboard backlight device" and nothing shows (O5). `osd display keyboard <0..1> false` shows it for tests. Accessible name "Keyboard brightness N%" (fr « Luminosité du clavier N % »). The input-source popup is requirement 9. Test: `tests/shell/osd_keyboard.sh` (offscreen, dev session, shims that fail if `brightnessctl` runs).

9. O9 Input source HUD (macOS: the input source name appears when the keyboard layout changes; owner decision 2026-10-23): the same pill, `kind` `inputsource`, the `keyboard` glyph and the layout name (elided, `Osd.label`) in place of the bar, shown for `osd.hideDelay` when the compositor reports a layout change. `platform/InputSource.qml` listens to Hyprland's `activelayout>>keyboard,layout` event (event-driven; the only code that talks to the compositor) and `InputSource.js` decides (`tests/unit/tst_inputsource.qml`): the first layout seen on a keyboard is remembered without a HUD, so a session with one configured layout never shows anything (nothing says how many layouts exist, a change is the signal); a different layout on the same keyboard shows it; keyboards are independent; malformed events and names over 128 characters are ignored; an event whose layout has no readable name (Hyprland reports `error` for a virtual keyboard that brings its own keymap, such as wtype) is ignored too, the input source being the system's and not a virtual keyboard's (macOS). The name is shown in the shell's language: Hyprland sends the English xkb description ("English (US)"), `platform/layout-names.py LANGUAGE NAME...` reads xkeyboard-config's own gettext catalog (`xkeyboard-config-2`, then `xkeyboard-config`) with Python's gettext module (no generated locale needed) and prints the translated name, the English one when there is none; `InputSource.qml` runs it once per name and language (English: no helper), and Settings reads the same catalogs the same way. Tests: `tests/shell/input_source_names.sh`. O4 applies (nothing in the first 1.5 s). Accessible name "Input source <name>" (fr « Source de saisie : <name> »). Hooks (dev session only): `osd layout "<keyboard>,<name>"` feeds an event, `osd state` prints `shown|kind|label`. Tests: `tests/shell/osd_keyboard.sh` (logic, offscreen) and nested `tests/visual/osd-inputsource.sh` (HUD and its absence, capture).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| O1/O2 | `qs ipc call osd display volume 0.6 false` then `scripts/dev/shot.sh osd-volume WAYLAND-1`: pill with icon and 60 % bar | L1 |
| O6 | `wpctl get-volume`, `qs ipc call volume up`, `wpctl get-volume` = +0.05, OSD visible; `volume down` restores | L1 |
| O7 | `qs ipc call brightness up` in nested: log "dev session, not changing the backlight", `actual_brightness` unchanged, OSD shows | L1 |
| O5 | on a machine without backlight, `brightness up` logs "no backlight device" | L1 (not run here: the dev machine has intel_backlight) |

## Interfaces / contracts
IPC targets (Quickshell IPC, `qs -p <shell> ipc call ...`): `osd display <volume|brightness|keyboard> <0..1> <muted>` and `osd hide` (tests; the
function is not called `show` because `qs ipc` reserves that word), `volume up|down|mute`, `brightness up|down`, `keyboard up|down` (backlight; bind the keyboard-backlight keys of the session config to it).
Tokens: `osd.*` (width, height, iconSize, barHeight, gap, hideDelay). Services: `qs.services.Brightness` (device, level, available).
Window: layer-shell Overlay, namespace `grassfield-osd`, the active display only (`Compositor.activeScreenName`: the focused output, the first as a last resort; macOS).

## Dependencies (verified versions)
Quickshell 0.3.1 (`Quickshell.Services.Pipewire`, `Quickshell.Io`), `wpctl` and `brightnessctl` in `/usr/bin` (verified present),
Qt 6.11.2.

## Degraded behavior
No PipeWire sink: volume OSD never shows, `volume` IPC commands run `wpctl` which fails silently. No backlight or `brightnessctl`
missing: see O5; brightness changes by other programs are still shown when the sysfs file exists.

## Automated tests · manual verification
No unit-testable pure logic beyond tokens (covered by `tst_tokens`); L1 steps above. Evidence: `.dev/shots/osd-volume.png`,
`osd-volume-real.png`, `osd-brightness.png` (not committed).

## Performance · Accessibility · i18n
Idle cost: one 1.5 s file read while a backlight exists. The pill exposes `Accessible.ProgressBar` with name "Volume N%" /
"Brightness N%" (translated through `qsTr`). Reduce Motion shortens the fades.

## Known limitations
- Top-right pill only, on the active display (the focused output, not the first one); every screen-less surface (Notification Center, Search, Apps, switcher, centred popups, banners, OSD) opens by that one rule.
- Brightness is not changed in the dev session, so only the display path is verified there.
- No microphone OSD (the keyboard backlight HUD is requirement 8, the input source HUD 9: it shows names as the compositor reports them, not flags or abbreviations, and a real layout switch cannot be made in the nested session, which has one layout); no segmented/centered style. The keyboard HUD is not verified on hardware (the dev machine has no `kbd_backlight` LED): the logic is tested with a faked device, the look is the volume pill's.
- Volume cannot exceed 100 % (`-l 1`).
- Hardware keys are not bound yet (owner/Hyprland config task).
