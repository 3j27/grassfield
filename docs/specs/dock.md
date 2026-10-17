# dock spec · shell-engineer · M1

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
Not yet measured (F1 pending). Assumed: centered rounded translucent shelf at the bottom; icons magnify with a smooth falloff around the pointer and grow upward; a dot under running apps; a hairline separates apps from the Trash; a label appears above the hovered icon; the shelf can hide and slide in when the pointer touches the bottom edge.

## Purpose and non-goals
Pinned and running apps, Trash, launch/focus/cycle, magnification, autohide, item context menu. Non-goals now: folders/stacks, drag reordering, bounce animation, Trash emptying, per-monitor differences.

## Functional requirements
1. One layer-shell window per screen, namespace `grassfield-dock`, anchored bottom+left+right (full width, transparent), exclusive zone = shelf height + bottom margin (0 with autohide). Input is restricted with a mask to the shelf (plus the magnified area while hovered), or to a 2 px bottom strip while hidden.
2. Items (`DockModel.js`, pure): pinned desktop entry ids in the user's order (unresolvable ids skipped, duplicates merged), then running apps that are not pinned (foreign-toplevel app id mapped to an entry; case-insensitive), a separator, the Trash. Windows are never matched by title.
3. Running indicator dot under apps with at least one window.
4. Click, Return, Space: not running → `DesktopEntry.execute()`; running and not focused → activate the most recently focused window of the app (and move it back from `special:hidden`); running and already focused → cycle to the app's next window. Trash → `gio open trash:///`.
5. Tooltip with the app name above the icon (hover or keyboard focus), via the `Tooltip` component.
6. Magnification (`Magnify.js`, pure): scale = 1 + (max-1)·(cos(π·d/R)+1)/2 for pointer distance d < R, R = `dock.magnificationRadius` (3) icon pitches; max = `dock.magnification` (default 1.6, clamp 1–2.5); disabled when `dock.magnificationEnabled` is false. Layout is computed from the unmagnified geometry; magnification eases in/out in `motion.fast`.
7. Autohide (`dock.autohide`, default false): hidden until the pointer hits the bottom edge; hides `dock.hideDelay` (450 ms) after the pointer leaves; slides in `motion.normal`. Reduce Motion caps the durations at 100 ms. The dock stays revealed while its context menu or keyboard mode is active.
8. Context menu (right click, or the Menu key on a focused item): Open / New Window, the desktop entry's actions (`DesktopEntry.actions`), Keep in Dock / Remove from Dock (persisted), Quit (close all windows of the app).
9. Trash icon: `trash`/`trash-full` from branding, by `~/.local/share/Trash/files` emptiness (`find` at start and on hover, then on every `gio monitor` event). Read-only.
10. Keyboard: the dock takes keyboard focus only in keyboard mode (IPC `dock keyboard`, to be bound to a shortcut by the integrator): Tab/Shift+Tab move, Return opens, Menu key opens the item menu, Esc leaves the mode. Focus ring is 2 px accent.

11. Minimized section (ADR-0002, master-prompt 5.6): right of the separator and before the Trash, one tile per window minimized by the shell (`Compositor.minimized`, newest last). Tile = app icon; in the `full` material profile a live `ScreencopyView` thumbnail with a small app-icon badge. Tooltip and accessible name: window title, ", minimized". Click, Return or Space restores the window to the current workspace and focuses it. Clicking an app icon whose windows are all minimized restores the most recent one; cycling skips minimized windows while the app has others. Closed windows leave the section.
12. Minimize paths: titlebar button (the plugin posts `grassfield>>{"type":"minimize-request","address":"…"}`; the address is validated as hex and mapped to a toplevel), Window menu, IPC `windows minimize` (bound to SUPER+M). `Compositor.minimize()` uses `hl.plugin.grassfield.minimize(address, x, y, w, h)` with the Dock rectangle (`Compositor.dockTarget`, first slot right of the separator, global coordinates) when `Capabilities.has("minimize")`; otherwise it moves the window to `special:minimized`. Both branches record the window in the shell. `unminimize()` calls the plugin `restore(address)` or moves the window to the focused workspace, then activates it. The plugin branch is untested until the plugin implements those verbs (it advertises only `decorations` today).

## grassfield.json keys (contract version 1; the integrator adds the schema)
`dock.pinned` (string array, default `["foot","chromium","org.gnome.Nautilus"]`), `dock.magnification` (number 1–2.5, default 1.6), `dock.magnificationEnabled` (bool, default true), `dock.autohide` (bool, default false).

## Acceptance criteria
- Screenshots: magnified (hover simulated via IPC), autohide hidden/revealed, item menu (L2). `tests/unit/tst_magnify.qml`, `tst_dockmodel.qml` (L0). Settings round trip `tests/shell/settings_roundtrip` (L1).

## Interfaces / contracts (versions)
`Compositor.toplevels/activate/mostRecent/nextAfter/close/minimized/minimize/unminimize/isMinimized/dockTarget`, `Settings.dock*`, `Popups` (kind `dock`), `Trash`. Test hooks (`IpcHandler dock`): `hover x`, `unhover`, `reveal on`, `autohide on`, `magnify factor enabled`, `click index`, `keyboard`, `menu index output`.

## Dependencies (verified versions)
Quickshell 0.3.1: DesktopEntries/DesktopEntry.actions, IconImage, WlrLayershell, ToplevelManager, Process. `gio` (glib) for the Trash monitor and open.

## Degraded behavior
No desktop entry for a running app: shown with the app id and a theme icon of the same name (generic icon if missing), no pin option. No `gio monitor`/missing Trash directory: Trash reads as empty and refreshes on hover only.

## Automated tests · Manual verification steps
`scripts/dev/test.sh`. Manual: nested-up, launch foot, `qs ipc call dock hover 960`, `shot.sh`.

## Performance · Accessibility · i18n
Model rebuilt on toplevel, application or pin changes; no polling. Tiles are `Accessible.Button` with names (", running"; Trash state). Strings via `qsTr()`.

## Known limitations
- Real pointer hover, edge reveal and tooltips were checked through IPC test hooks and keyboard focus, not with a physical pointer (wtype is keyboard only).
- Window cycling order is the foreign-toplevel list order. Hidden (special workspace) windows are brought back by Dock click or Show All. Live thumbnails of minimized windows depend on the compositor still rendering windows parked on a special workspace; not verified (the nested run used the `balanced` profile, icon tiles).
- Dock icons come from the installed theme and are not Grassfield artwork. No bounce, drag or stacks. The minimize animation toward the Dock is plugin work (not implemented); the fallback hides the window at once.
- Magnified icons grow upward; the shelf keeps its height and only widens.
