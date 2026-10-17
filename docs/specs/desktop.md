# desktop spec (hot corners) · shell-engineer · M2

## macOS reference behavior (described in words, no Apple images committed)
Not yet measured (F1 pending). Assumed: moving the pointer into a screen corner and resting there for a short moment triggers a user-chosen action (Mission Control, Notification Center, Launchpad, lock screen); each of the four corners is configured separately and "none" disables it.

## Purpose and non-goals
Hot corners on every screen, configured in `grassfield.json`. Non-goals now: a Settings UI to choose the actions (the keys are written by `Settings.setHotCorner`, a UI comes with System Settings, M4), modifier keys that must be held, corner animations. The wallpaper (`Wallpaper.qml`) is documented in `ui.md`.

## Functional requirements
1. Per screen and corner one layer-shell window (`HotCorner.qml`), namespace `grassfield-hotcorner`, layer Overlay (reachable above fullscreen apps), anchored to the corner, `Tokens.hotCornerSize` (2 px) square, transparent, exclusion mode Ignore (no exclusive zone), keyboard focus None. A corner whose action is `none` is not mapped at all.
2. Dwell: `DwellGate` fires once, `Tokens.hotCornerDwellMs` (150 ms) after the pointer entered the corner window; leaving earlier cancels it; after firing the gate stays latched until the pointer is proven to have left. The corner window never grows (it would steal clicks from the menu button): `PointerTracker` (`services/`) receives pointer positions from HoverHandlers on the menu bar, the wallpaper and the Dock, and a reported position more than 8 px from the corner, or a corner hover exit later than 800 ms after firing, re-arms. Closing Overview with the pointer still in the corner therefore does not reopen it, while leaving and jumping straight back re-fires. No firing while the target surface is open (notifications).
3. Actions (`HotCornerActions.js`, pure): `none`, `overview` (`qs ipc call overview toggle`), `notifications` (in-process `Notifications.toggleCenter(screen)` with the corner's output, so the Notification Center opens on the screen that fired), `lock` (`lock lock`), `apps` (`apps toggle`). Calls go through `qs ipc --pid <this shell>` so surfaces stay decoupled. `apps` is the future Apps/Launchpad surface: `qs ipc show` is read first and the call is made only when the target `apps` exists, otherwise nothing happens.
4. Settings: `hotCorners.topLeft|topRight|bottomLeft|bottomRight`, enum `none|overview|notifications|apps|lock`, default `none` (`config/schema/grassfield.schema.json`). `SettingsStore` clamps unknown values to `none`; `Settings.hotCorner*` read, `Settings.setHotCorner(corner, action)` writes. Edits to the file apply live (the store watches it).
5. Click safety: the 2 px corner windows never overlap a control. The menu bar buttons start `spacingXs` px from the screen edge (the Grassfield menu at the left, the clock at the right) and the Dock is centered, so a click in the very corner pixel hits nothing clickable. If a future control sits in a corner, move it inward instead of changing this window.

## Acceptance criteria
- `tests/unit/tst_hotcorners.qml`: dwell fires after the interval, cancels on leave, fires once per visit, token is 150, actions clamp to the enum, IPC argv, apps target detection (L0).
- Nested screenshot with `hotCorners.topLeft = "overview"` and the real pointer moved to the corner: Overview opens (L2, `.dev/shots/hotcorner.png`).

## Interfaces / contracts (versions)
`grassfield.json` contract version 1 keys above; reads `Settings`; calls the IPC targets `overview`, `notifications`, `lock`, `apps`.

## Dependencies (verified versions)
Quickshell 0.3.1: PanelWindow, WlrLayershell, HoverHandler, Process, `Quickshell.processId`, `qs ipc`.

## Degraded behavior
Unknown config value: `none`. Target surface missing (`apps`): no-op. No compositor plugin needed.

## Automated tests · Manual verification steps
`scripts/dev/test.sh`. Manual: set `"hotCorners":{"topLeft":"overview"}` in `.dev/config/grassfield.json`, nested-up, `scripts/dev/pointer.sh output GF-REF abs 400 400 sleep 300 abs 0 0 sleep 900`, `shot.sh`.

## Performance · Accessibility · i18n
No timers run until the pointer is in a corner. Corners are pointer-only; every action has a keyboard path (CTRL+UP Overview, SUPER+N Notification Center, SUPER+CTRL+Q lock). No user-visible strings.

## Known limitations
- A real pointer is clamped to the output edge, so a corner is reached only on an edge shared with the screen boundary; with side-by-side outputs, the inner corners are not at the pointer's stop and still work only where the pointer can reach them.
- The Overlay-layer corner windows cover the 2 px corner of the Control Center/popup overlay and of fullscreen apps by design.
- The `apps` IPC target name (`apps`, function `toggle`) is an assumption until the Apps surface exists.
- Jumping from a hot corner onto a client window and straight back to the corner within 800 ms does not refire it: client windows do not report the pointer position to the shell, so the shell sees no exit/re-entry.
