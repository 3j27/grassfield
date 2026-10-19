# dock spec · shell-engineer · M1

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
Measured in F1 (docs/testing/f1-reference-gaps.md, Dock): a floating rounded-rectangle glass shelf (radius about 24, not a capsule) about 6 pt above the bottom edge, a little lighter than its backdrop with a visible light rim along the top edge, strongly translucent over the wallpaper; icon body about 0.735 of the pitch; a small dark dot under running apps; a hairline separator before the folders and the Trash; a label capsule with a downward tail above the hovered icon; an icon menu (rounded panel with a tail) above the icon. Icons magnify only when the option is on (off by default).

## Look (fidelity pass, 2026-10-19)
The shelf is `Material` with the Dock overrides: tint alpha `dock.tintAlpha` (0.42, not the A2 text clamp: the shelf holds icons only, the labels are separate capsules on the global material), highlight `dock.highlightOpacity` (0.34) and a white 1 px rim `dock.rimOpacity` (0.34), always over a real compositor blur region (`BackgroundEffect.blurRegion`, nothing faked). Reduce Transparency still makes the shelf opaque (the override applies only while the material is not opaque). Radius `radius.dock` 24, padding `dock.padding` 10, separator `dock.separatorHeight` 49, spacing 4. The Trash uses the icon theme (`user-trash` empty, `user-trash-full`) in the user's icon mode (`TintedIcon`, ADR-0014); without those theme icons it falls back to the symbolic glyph on a rounded tile. The menu tail is `dock.menuTailWidth/Height/Gap` (19 / 13 / 16).

## Purpose and non-goals
Pinned, running and recent apps, Trash, launch/focus/cycle, launch bounce, badges, drag to reorder/remove, file drops, magnification, autohide, item context menu. Non-goals now: folders/stacks, left/right Dock position, Trash emptying, per-monitor differences.

## Functional requirements
1. One layer-shell window per screen, namespace `grassfield-dock`, anchored bottom+left+right (full width, transparent), exclusive zone = shelf height + bottom margin (0 with autohide). Input is restricted with a mask to the shelf (plus the magnified area while hovered), or to a 2 px bottom strip while hidden.
2. Items (`DockModel.js`, pure): pinned desktop entry ids in the user's order (unresolvable ids skipped, duplicates merged), then running apps that are not pinned (foreign-toplevel app id mapped to an entry; case-insensitive), a separator, the Trash. Windows are never matched by title.
3. Running indicator dot under apps with at least one window: it follows the appearance (macOS: pure white in dark mode, pure black in light mode, `colors.indicator`), and the shelf tint alpha is chosen per appearance (`dock.tintAlphaDark` 0.52, `dock.tintAlphaLight` 0.42) so that the dot keeps 3:1 or more against the shelf over ANY backdrop, wallpaper or window (black, white, greys, noise: autohide and floating windows put a window under the shelf): worst case 3.4:1 in dark (white backdrop), 3.7:1 in light (black backdrop), computed by tests/unit/tst_bartone.qml with `BarToneLogic.shelfLuminance` and measured by tests/visual/contrast.sh `dock`. No wallpaper sampling is needed.
4. Click, Return, Space: not running → `DesktopEntry.execute()`; running and not focused → activate the most recently focused window of the app (and move it back from `special:hidden`); running and already focused → cycle to the app's next window. Trash → `gio open trash:///`.
5. Tooltip with the app name above the icon (hover or keyboard focus), via the `Tooltip` component.
6. Magnification (`Magnify.js`, pure): scale = 1 + (max-1)·(cos(π·d/R)+1)/2 for pointer distance d < R, R = `dock.magnificationRadius` (3) icon pitches; max = `dock.magnification` (default 1.6, clamp 1–2.5); disabled when `dock.magnificationEnabled` is false. Layout is computed from the unmagnified geometry; magnification eases in/out in `motion.fast`.
7. Autohide (`dock.autohide`, default false): hidden until the pointer hits the bottom edge; hides `dock.hideDelay` (450 ms) after the pointer leaves; slides in `motion.normal`. Reduce Motion caps the durations at 100 ms. The dock stays revealed while its context menu or keyboard mode is active.
8. Context menu (right click, or the Menu key on a focused item; `shell/overlay/DockMenu.qml`, a panel with a tail pointing at the icon): Open / New Window, the desktop entry's actions (`DesktopEntry.actions`), Options (Keep in Dock / Remove from Dock, Open at Login, Show in Files), Show All Windows (`Compositor.bringAllToFront`), Hide (`Compositor.hideApp`), Quit (close all windows of the app). Open at Login writes or removes `<autostart dir>/<entry id>.desktop` (`AppLaunch.autostartFile`/`autostartText`: values escaped per the Desktop Entry spec, control characters in Exec refused, plain file names only; written by `overlay/write-autostart.sh`, temp file + rename; in a dev session `<dev>/apps-home/config/autostart`, never the owner's). Show in Files opens the folder of the entry's executable (`command -v`, `readlink -f`) through `Apps.openDetached`.
9. Trash icon: the theme's `user-trash` / `user-trash-full` (fallback `trash`/`trash-full` from branding), by `~/.local/share/Trash/files` emptiness (`find` at start and on hover, then on every `gio monitor` event). Read-only.
10. Keyboard: the dock takes keyboard focus only in keyboard mode (IPC `dock keyboard`, to be bound to a shortcut by the integrator): Tab/Shift+Tab move, Return opens, Menu key opens the item menu, Esc leaves the mode. Focus ring is 2 px accent.

11. Minimized section (ADR-0002, master-prompt 5.6): right of the separator and before the Trash, one tile per window minimized by the shell (`Compositor.minimized`, newest last). Tile = app icon; in the `full` material profile a live `ScreencopyView` thumbnail with a small app-icon badge. Tooltip and accessible name: window title, ", minimized". Click, Return or Space restores the window to the current workspace and focuses it. Clicking an app icon whose windows are all minimized restores the most recent one; cycling skips minimized windows while the app has others. Closed windows leave the section.
12. Minimize paths: titlebar button (the plugin posts `grassfield>>{"type":"minimize-request","address":"…"}`; the address is validated as hex and mapped to a toplevel), Window menu, IPC `windows minimize` (bound to SUPER+M). `Compositor.minimize()` uses `hl.plugin.grassfield.minimize(address, x, y, w, h)` with the rectangle of the window's own tile (`Compositor.dockRect`: the Dock of the window's monitor, slot = separator + 1 + the window's index in the minimized list, global layout coordinates; each per-screen Dock registers with `Compositor.registerDock` and unregisters on destruction) when `Capabilities.has("minimize")`; otherwise it moves the window to `special:minimized`. Both branches record the window in the shell. `unminimize()` calls the plugin `restore(address, x, y, w, h)` toward the window's current tile on the focused monitor's Dock, or moves the window to the focused workspace, then activates it.

13. Launch bounce: starting an app from the Dock makes its icon hop (`dock.bounceHeight` 24, `dock.bounceDuration` 420) until the app has a window or `dock.launchTimeout` (12 s) passes (`DockModel.bounceKeys`); the hop ends with a landing (a few small rebounds, `motion.normal`), not a snap. No bounce with Reduce Motion.
14. Badges: a red count bubble at the top right of an app icon from the notification history (`DockModel.badgeCount`: entries whose app name is the tile's name or entry id, case-insensitive; "99+" above 99). Read-only; the Dock never clears notifications.
15. Drag to reorder: pressing and dragging an app tile moves it; neighbours make room; on release `DockModel.reorder` returns the new pinned list (a running or recent app dropped before a pinned one becomes pinned). Dragged more than `dock.dragOutDistance` (56) above the shelf top a pinned or recent app that is not running shows a "Remove" capsule and, on release, leaves the Dock with a puff (`dock.poofDuration` 420, own drawing: fading circles) and is unpinned. A running app is never removed (it keeps its tile). Tiles are not rebuilt while a tile is dragged (a window opening or closing waits for the release, then the latest state is applied), so a release always finishes the drag. The drag is clamped so that the "Remove" capsule stays inside the window (`dock.dragArea` 168).
16. File drops (macOS: a tile accepts a drop only if the app can open that document): a tile highlights and accepts files (text/uri-list) only when the entry's Exec has a file field code (`%f %F %u %U`) AND its `MimeType` matches the type of every file (type from the shared MIME database by file name, with subclasses and aliases; an entry without `MimeType` accepts nothing; `DockModel.acceptsFiles`, data from `dock/mime-data.sh` via `Apps.mimeData`). Folders and files without a recognised extension are typed at drop time, for the dropped paths only (`dock/file-types.sh`: folders are `inode/directory`, others by content through `gio info`, bounded, off the UI path, FIFOs and devices never opened): while hovering such a path lets the tile highlight, the drop decides (a folder dropped on Files opens it). Opening substitutes the field codes per the spec (`DockModel.commandsForFiles`: `%F %U` one launch with all files, `%f %u` one launch per file, `%u %U` as file:// URIs); nothing is ever appended to a command line (a file dropped on `foot` is refused, not run). Isolated environment in dev. If the URI list cannot be read while hovering, the tile highlights and the drop itself decides. Files dropped on the Trash are moved to the trash (`gio trash`, isolated trash in dev).
17. Recent applications (the recent list is not evaluated before the desktop entries and the hidden-entry list are loaded, so a hidden entry never takes a slot; `DockModel.recentsStep`) (macOS: their own section between the app tiles and the Trash section, set off by a separator): apps launched from the Dock, and apps that were running and quit while not kept in the Dock, are remembered (`dock.recent`, at most `dock.recentMax` 3, newest first, `DockModel.recentsAfter`: a pure function of the previous and current running sets, so the list is written only when it really changes and an app evicted by the cap is never re-added while it still runs). Whenever tiles are rebuilt they glide from where their key was to where it is now (an app that quits without being kept in the Dock moves into the recents section instead of jumping; new tiles fade in; none with Reduce Motion; `DockModel.layoutTransition`). They are shown after a divider, before the separator and the Trash, when `dock.showRecents` is on (default true), without a dot. NoDisplay / hidden entries are never remembered or shown (`Apps.isListed`).
18. Minimize into the application icon (`dock.minimizeIntoApp`, default false): minimized windows get no tile of their own; the window animation targets (and leaves from) the tile of its app (`tileRect(index, adding, toplevel)`, `Compositor.dockRect(..., toplevel)`). Only the target rectangle changes; the animation itself is the compositor plugin's.

## grassfield.json keys (contract version 1)
`dock.pinned` (string array, default `["foot","chromium","org.gnome.Nautilus"]`), `dock.magnification` (number 1–2.5, default 1.6), `dock.magnificationEnabled` (bool, default false, as macOS), `dock.autohide` (bool, default false), `dock.recent` (string array, owned by the Dock), `dock.showRecents` (bool, default true), `dock.minimizeIntoApp` (bool, default false). The Settings app exposes magnification, autohide, recent applications and minimize into icon.

## macOS parity checklist (fidelity pass 2026-10-19)
| Behaviour | Status |
|---|---|
| Translucent shelf, real blur, rim, radius, padding, separator, tooltip capsule with tail, menu with tail | present (this pass; tokens above) |
| Theme Trash icon, empty/full state | present |
| Running indicator dots | present |
| Launch bounce | present (this pass) |
| Notification badges | present (this pass; counts from the notification history) |
| Click on a running app raises its latest window; all windows minimized: restore | present |
| Click on the active app | differs: cycles to its next window (macOS does nothing) |
| Right-click menu: Options (Keep in Dock, Open at Login, Show in Files), Show All Windows, Hide, Quit | present (this pass) |
| Recent items in the menu (recent documents) | missing (no recent-documents source) |
| Drag to reorder | present (this pass) |
| Drag out to remove with poof | present (this pass; own puff drawing, not Apple's sprite) |
| Drop files on app icons to open | present (accepts only documents the app can open; unit-tested model and command building; a real drag source could not be driven in the nested session: the pointer events after the drag enter were not delivered, see STATE) |
| Drop on Trash moves to trash | present (isolated trash in dev) |
| Recent applications section | present (own section after a divider, then the Trash separator) |
| Magnification option, off by default | present |
| Auto-hide | present |
| Minimize into app icon (setting + target tile) | present (setting, model and target rect; the animation is plugin work) |
| Genie / Scale minimize effect choice | missing (plugin) |
| Dock position left / right | missing (the layout, hit areas, tooltips and `dockRect` are bottom-only) |
| Folder / Downloads stack (fan or grid) | missing |
| Empty Trash from the Dock menu | missing (never in dev; deliberately not added) |
| Dock shrinks to fit a full screen | missing |
| Per-app Dock icon bounce for attention requests | missing |

## Acceptance criteria
- Screenshots: magnified (hover simulated via IPC), autohide hidden/revealed, item menu (L2). `tests/unit/tst_magnify.qml`, `tst_dockmodel.qml` (L0). Settings round trip `tests/shell/settings_roundtrip` (L1).

## Interfaces / contracts (versions)
`Compositor.toplevels/activate/mostRecent/nextAfter/close/minimized/minimize/unminimize/isMinimized/registerDock/unregisterDock/dockRect`, `Settings.dock*`, `Popups` (kind `dock`), `Trash`. Test hooks (`IpcHandler dock`): `hover x`, `unhover`, `reveal on`, `autohide on`, `magnify factor enabled`, `click index`, `keyboard`, `menu index output`.

## Dependencies (verified versions)
Quickshell 0.3.1: DesktopEntries/DesktopEntry.actions, IconImage, WlrLayershell, ToplevelManager, Process. `gio` (glib) for the Trash monitor and open.

## Degraded behavior
No desktop entry for a running app: shown with the app id and a theme icon of the same name (generic icon if missing), no pin option. No `gio monitor`/missing Trash directory: Trash reads as empty and refreshes on hover only.

## Automated tests · Manual verification steps
`scripts/dev/test.sh`. Manual: nested-up, launch foot, `qs ipc call dock hover 960`, `shot.sh`.

## Dev notes: isolated app launches
In a `GRASSFIELD_DEV=1` session the shell runs on the owner's machine, so an app started from the Dock, Apps, Search, the Dock/app menus or by opening a desktop file must never use the owner's profiles (incident: Chromium launched from the nested Dock with the default profile). `Apps.launch(entryOrAction)` (`shell/services/Apps.qml`, the one launch path; helpers in `AppLaunch.js`, `tests/unit/tst_applaunch.qml`) starts the entry's `command` (Exec field codes dropped; `runInTerminal` through `xdg-terminal-exec`) with `Quickshell.execDetached({command, environment})` and `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME` set to `<dev>/apps-home/{config,cache,state,data}` (`<dev>` is the parent of `GRASSFIELD_STATE_HOME`, i.e. `.dev/`, which is ignored by version control). `XDG_DATA_DIRS` is kept so system desktop entries and icons resolve. The Dock Trash tile (`gio open trash:///`) and the Quick Settings Wi-Fi editor (`nm-connection-editor`) go through `Apps.openDetached` too. File openers (`gio open`, `xdg-open`, `gtk-launch` for desktop files and Search results) get the same environment through `Apps.openDetached` / `Apps.openEnvironment`. Outside a dev session `DesktopEntry.execute()` is called unchanged. Check: launch foot from the nested Dock, then `tr '\0' '\n' < /proc/<pid>/environ | grep XDG_`.

## Performance · Accessibility · i18n
Model rebuilt on toplevel, application or pin changes; no polling. Tiles are `Accessible.Button` with names (", running"; Trash state). Strings via `qsTr()`.

## Known limitations
- Real pointer hover, edge reveal and tooltips were checked through IPC test hooks and keyboard focus, not with a physical pointer (wtype is keyboard only).
- Window cycling order is the foreign-toplevel list order. Hidden (special workspace) windows are brought back by Dock click or Show All. Live thumbnails of minimized windows depend on the compositor still rendering windows parked on a special workspace; not verified (the nested run used the `balanced` profile, icon tiles).
- Dock icons come from the installed theme and are not Grassfield artwork. No stacks, no left/right position.
- Drag and release were tested with `scripts/dev/pointer.sh` in ONE invocation (press, drag, release); a release sent from another invocation does not end the drag (a virtual pointer destroyed while pressed leaves the button down for the shell): a test harness artefact. The minimize animation toward the Dock is plugin work (not implemented); the fallback hides the window at once.
- Magnified icons grow upward; the shelf keeps its height and only widens.
