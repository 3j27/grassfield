# Quick Settings spec · shell-engineer · M2

UI naming (renamed 2026-10-18, owner decision): internally `controlcenter` / `ControlCenter.qml`; the user sees "Quick Settings" (fr « Réglages rapides »). The Focus tile is "Do Not Disturb" (fr « Ne pas déranger »), subtitle On/Off.

## macOS reference behavior (described in words)
- Opens from the Quick Settings icon (two toggles) at the right of the menu bar as a ~320 pt wide material
  panel anchored under the icon, rounded ~18 pt.
- Modules in a grid: Wi-Fi / Bluetooth / AirDrop-like tile (we show Wi-Fi, Bluetooth, Airplane mode),
  Do Not Disturb tile, Display brightness slider, Sound slider with output device chevron, Now Playing tile,
  optional Keyboard brightness. Clicking a tile's chevron expands it in place (list of networks/devices).
- Toggles are rounded tiles with an icon circle filled with the accent when on.

## M1 subset (implemented, shell-engineer)
Opened by the Quick Settings menu bar icon (`qs.overlay/ControlCenter.qml`, 320 px, anchored under the icon): Appearance (Light/Dark), Transparency slider (`material.transparency` 0–1, live), Reduce Transparency toggle, Reduce Motion toggle, output volume slider. Everything persists to grassfield.json through `Settings` (see ui.md). Verified: screenshots at transparency 0, 0.25, 0.6 and in the light appearance; `grassfield.json` written in the dev config dir. 

## M2 implementation (shell-engineer)
`shell/overlay/ControlCenter.qml` + `shell/overlay/controlcenter/*` (pure logic in `Model.js`, tests `tests/unit/tst_ccmodel.qml`).
- Layout: connectivity tile (Wi-Fi, Bluetooth, Airplane Mode) left; Do Not Disturb and Now Playing right (Do Not Disturb fills the column when no player runs); Display slider (hidden without backlight); Sound slider with mute button and device chevron; Keyboard Brightness (only with a `*kbd_backlight` LED); Appearance row expanding to Appearance + Material. One section expanded at a time; the detail card opens under the tile grid (full width) rather than inside the half-width tile.
- Wi-Fi: Quickshell Networking; scan list (deduplicated, connected first, then strength), lock icon for secured, connect to known/open networks, new WPA/WPA2/WPA3-personal network: inline password field (`connectWithPsk`), 802.1X: `nm-connection-editor`. Scanning is enabled only while the list is open. SSIDs are PlainText and elided.
- Bluetooth: paired devices, connect/disconnect, battery if exposed. Devices are not discovered or paired from here (no pairing flow).
- Airplane Mode: derived (on when every present radio is off); switches the Wi-Fi radio (NetworkManager) and the Bluetooth adapter power (BlueZ). It is NOT an rfkill soft block, and the label says "Wi-Fi and Bluetooth off".
- Sound: output and input device lists (PipeWire), default checked.
- Keyboard: Tab and Up/Down move between controls, Space/Return activate, Right/Left expand/collapse rows and the sound chevron, Esc closes; sliders use arrows.
- Dev guard (`GRASSFIELD_DEV=1`): Wi-Fi/Bluetooth/airplane toggles, connects, device switches and mute are not executed (logged as `dev guard: ... suppressed`, header shows "dev: not applied"); volume stays within +-5 % of its starting value and is restored when the panel closes; brightness is never changed.
- Known gaps: Now Playing transport and Bluetooth device lists are not exercised in the dev session guard (player controls act on the real player); keyboard backlight and Bluetooth device rows unverified on this hardware (no kbd LED, no paired devices).

## Purpose and non-goals
Quick settings backed by real services only (§5.8): NetworkManager (Quickshell Networking), BlueZ (Quickshell
Bluetooth), PipeWire (Quickshell Pipewire), UPower, MPRIS, brightness via `brightnessctl` or logind
`SetBrightness` (no root). Non-goals: AirDrop, Screen Mirroring (no backend), privileged commands from QML.

## Functional requirements
1. CC1 Wi-Fi tile: on/off, current SSID; expand → scan list, connect to known/open networks; secured new
   network → password field (NetworkManager agent via Quickshell if available, else open `nm-connection-editor`).
2. CC2 Bluetooth tile: power on/off, expand → paired devices connect/disconnect.
3. CC3 Airplane mode: rfkill via NetworkManager/BlueZ soft block (no root).
4. CC4 Do Not Disturb tile ↔ notifications DND.
5. CC5 Display brightness slider (hidden if no backlight device), keyboard brightness if present.
6. CC6 Sound: output volume slider + mute; expand → output device list (Pipewire sinks); input device list.
7. CC7 Now Playing: MPRIS title/artist/art, play/pause/next/prev on the active player.
8. CC8 Material: transparency slider (`material.transparency`, 0–1) and appearance (Light/Dark/Auto).
9. CC9 Keyboard: Tab/arrow navigation across tiles, Space toggles, Esc closes; every control has Accessible.name.
10. CC10 All values update live from the services (no polling except what the service APIs require).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| CC5/6 | change slider via IPC → `wpctl get-volume @DEFAULT_AUDIO_SINK@` matches | L1 |
| CC8 | slider at 0 / 0.25 / 0.6 → 3 screenshots, A2 contrast script passes | L1 |
| CC9 | keyboard-only scenario reaches every control | L1 |
| CC1–3 | owner checks with real hardware | L2† |

## Degraded behavior
Missing service → tile hidden with a note in the spec, never a fake toggle.

## Known limitations
- Wi-Fi Enterprise (802.1X) setup delegates to nm-connection-editor.
- No AirDrop / Screen Mirroring equivalents.
