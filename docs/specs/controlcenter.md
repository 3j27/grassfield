# Quick Settings spec · shell-engineer · M2

UI naming (renamed 2026-10-18, owner decision): internally `controlcenter` / `ControlCenter.qml`; the user sees "Quick Settings" (fr « Réglages rapides »). The Focus tile is "Do Not Disturb" (fr « Ne pas déranger »), subtitle On/Off. A long module title wraps to a second line inside its tile (two lines at most, then an ellipsis; no font shrink), as macOS does; the accessible name stays "title, state".

## macOS reference behavior (described in words; measured in docs/testing/f1-reference-gaps.md, gap 6)
- Opens from the Quick Settings icon (two toggles) at the right of the menu bar. There is no shared panel: every module
  is its own glass shape on a 4-column grid (cells 63 pt, gaps 13, 291 pt wide), 14 pt from the right edge of the screen and
  about 13 pt below the bar.
- Modules: Wi-Fi / Bluetooth / AirDrop 2x1 capsules (139 x 63; we show Wi-Fi, Bluetooth, Airplane Mode), Do Not Disturb 2x1,
  Now Playing 2x2 (138 x 139, radius ~30), Display and Sound slider modules (291 x 63, radius 20, bold title, 4 pt track).
- Clicking a capsule's text opens that module as a detail panel (a list of networks or devices) in place of the grid; a back
  button returns. The icon disk (36 pt, filled with the accent when on) toggles.

## M1 subset (implemented, shell-engineer; the 320 px single panel was replaced by the modules below)
Opened by the Quick Settings menu bar icon (`qs.overlay/ControlCenter.qml`): Appearance (Light/Dark), Transparency slider (`material.transparency` 0–1, live), Reduce Transparency toggle, Reduce Motion toggle, output volume slider. Everything persists to grassfield.json through `Settings` (see ui.md). Verified: screenshots at transparency 0, 0.25, 0.6 and in the light appearance; `grassfield.json` written in the dev config dir. 

## Fidelity pass 2: floating modules (shell-engineer)
`shell/overlay/ControlCenter.qml` + `shell/overlay/controlcenter/*` (pure logic in `Model.js`, tests `tests/unit/tst_ccmodel.qml`; `Module.qml` is the glass surface).
- Grid (tokens `quicksettings.*`, `panel.controlCenterWidth` 291): cell 63, gap 13, 4 columns. Left: Wi-Fi, Bluetooth, Airplane Mode (2x1 capsules, 36-pt icon disk, title wraps to two lines, status line). Right: Do Not Disturb (2x1) and, while a player runs, Now Playing (2x2); with no player Appearance (2x1) takes that slot and Airplane Mode spans the full width. Below: Display (hidden without a backlight), Keyboard Brightness (only with a `*kbd_backlight` LED) and Sound (mute, slider, device chevron) as 4x1 slider modules (radius 20, bold title, 4 pt track); Appearance as a 4x1 capsule when a player runs.
- Each module is its own `Module` (Material, no shadow). `ControlCenter.surfaces` lists the visible ones; `Overlay.qml` builds one blur region per surface (`Variants` of `Region`), so every module blurs on its own (never a fake blur); the hosting window stays one transparent layer-shell surface. Position: right edge at `quicksettings.edgeMargin` (14), top at the bar plus `quicksettings.topGap` (13), set in `Overlay.qml` (the menu bar item only opens the popup).
- Detail module: opening Wi-Fi, Bluetooth, Sound (output and input lists) or Appearance (Appearance + Material) replaces the grid with ONE 4-column module: back button, title, power toggle (Wi-Fi, Bluetooth), then the list. Esc and the Left key go back first, then Esc closes; focus returns to the capsule that opened it. The chevron of a capsule shows on hover, focus or while open (a 139-pt capsule has no room for it permanently).
- Keyboard (macOS model): Tab follows the grid rows (modules are declared in row order). Up/Down move focus to the module above or below and Left/Right to the control beside (spatial navigation, `Model.navTarget`), so walking the grid with Down never changes a value. A focused slider changes with Left/Right (Home/End: ends) only; its Up/Down move focus (`Slider.verticalKeys: false`; other sliders keep Up/Down as values). Space toggles a capsule; Return too, except on a capsule with a detail module (Wi-Fi, Bluetooth, Appearance), where Return opens it, and so does Right on the last capsule of a row. Left (or Esc) goes back in a detail module, then Esc closes.
- Not built (measured in the reference, no backend or out of scope): AirDrop, Screen Mirroring, Stage Manager and Screenshot 1x1 modules, edit mode (minus badges, controls gallery, size menu).
- Wi-Fi: Quickshell Networking; scan list (deduplicated, connected first, then strength), lock icon for secured, connect to known/open networks, new WPA/WPA2/WPA3-personal network: inline password field (`connectWithPsk`), 802.1X: `nm-connection-editor`. Scanning is enabled only while the list is open. SSIDs are PlainText and elided.
- Bluetooth: paired devices, connect/disconnect, battery if exposed. Devices are not discovered or paired from here (no pairing flow).
- Airplane Mode: derived (on when every present radio is off); switches the Wi-Fi radio (NetworkManager) and the Bluetooth adapter power (BlueZ). It is NOT an rfkill soft block, and the label says "Wi-Fi and Bluetooth off".
- Sound: output and input device lists (PipeWire), default checked.
- Dev guard (`GRASSFIELD_DEV=1`): Wi-Fi/Bluetooth/airplane toggles, connects, device switches and mute are not executed (logged as `dev guard: ... suppressed`, a "dev: not applied" capsule appears under the modules); nothing ever changes the owner's audio (volume, mute, default output or input, volume keys), brightness, keyboard backlight or the Now Playing transport: every audio write goes through `Audio.backendWrite()`, which refuses before touching the backend (no exception path; `tests/shell/audio_dev_guard.sh`). A slider whose change is refused snaps back to the real value.
- Known gaps: Bluetooth device lists are not exercised in the dev session guard keyboard backlight and Bluetooth device rows unverified on this hardware (no kbd LED, no paired devices).

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
