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

---

# Desktop icons v1 · shell-engineer

## macOS reference behavior (words)
The desktop shows the files and folders of the Desktop folder as large icons with wrapped labels (two lines at most), highlighted when selected, arranged in columns from the top-right corner. Dragging on empty space draws a selection rectangle, a double click opens, icons can be dragged to rearrange (positions are remembered), onto the Dock Trash to trash them, and into or out of applications. The context menu of empty space offers New Folder; the one of an icon offers Open, Rename, Copy and Move to Trash.

## Functional requirements
1. Surface: `DesktopIcons.qml` maps one layer-shell window per primary screen (the first screen; dev override `GRASSFIELD_DESKTOP_SCREEN=<output>`), namespace `grassfield-desktop-icons`, Background layer, created after the wallpaper (so above it) and below the Bottom-layer widgets surface (`DesktopWidgets.qml`, not touched). The window spans the screen and has no input mask: a click on empty desktop starts a rubber band (the desktop never takes the keyboard: see "Keyboard safe mode (2026-10-17)" below). The widgets layer above keeps its own input. It reports the pointer to `PointerTracker` (the wallpaper below no longer sees it). Nothing animates or repaints on a timer.
2. Folder: `$GRASSFIELD_DESKTOP_DIR`; else, in a dev session (`GRASSFIELD_DEV=1`), `<state>/desktop-sandbox`; else `xdg-user-dir DESKTOP`; else `~/Desktop` (also when XDG answers `$HOME`). `scripts/dev/shell-run.sh` always passes `GRASSFIELD_DESKTOP_DIR` (default `.dev/desktop-sandbox`). Model: `Qt.labs.folderlistmodel` (hidden files are not shown). The folder is never created or modified except by explicit user actions below.
3. Grid (`IconsLogic.js`, pure): slot (col, row), col 0 right-most. Unplaced icons take the first free slot column-first from the top-right, in case-insensitive name order. Cell, margins and sizes are tokens (`desktopIcon*`); the grid avoids the menu bar and the Dock footprint.
4. Icons: theme icon from an extension map (fallback `text-x-generic`), images show a thumbnail with `sourceSize` capped at `desktopIconThumbnailMax`. A `.desktop` file shows its `Name` and `Icon` as plain text (parsed, never executed).
5. Interaction: click selects (Ctrl toggles, Shift adds; a press on an icon that is already part of a multi-selection keeps the selection for a group drag, and the release without drag then leaves that icon alone selected, as in macOS); rubber band on empty space; double click opens; (keyboard safe mode, off for now: Return opens, arrows move the selection, F2 renames, Ctrl+Backspace moves the selection to the Trash, Ctrl+A selects all; Space opens Glance (`grassfield-preview --glance`) for the selection and closes it again when pressed once more (`shell/services/GlanceApp.qml`, dev override `GRASSFIELD_PREVIEW_CMD`, passed by `scripts/dev/shell-run.sh`); Esc clears). Context menus use `PopupMenu` in an Overlay window (`grassfield-icons-menu`) that holds the keyboard itself while it is open (see "Keyboard safe mode (2026-10-17)").
   Keyboard focus: SAFE MODE since 2026-10-17, see "Keyboard safe mode (2026-10-17)" below. The desktop surface never holds the keyboard on its own, so the keyboard actions of this item (Return, arrows, F2, Space, Ctrl+A, Ctrl+Backspace, Esc) are off until the macOS-model redesign; the pointer actions are unchanged.
   Rename focus: the view owns a dedicated key-sink item that is the focus item whenever no rename field is open; a finished rename or menu makes it the active focus item only while the desktop holds the keyboard. The field is `enabled` only while its icon is renaming, so a finished rename (commit or Esc) can never hand focus back to a hidden field, and `accepted` is ignored unless the field is visible and was opened by the user (`tests/shell/desktop_rename_focus`).
   Widgets: slots whose cell overlaps a desktop widget tile of the same screen (`Widgets.desktop`) are not available to icons (`Logic.blockedSlots`); icons on such slots move to the next free slot. Widgets win: they never reserve cells, they only block them.
6. File operations, only on those user actions and always as one argv: `gio trash`, `gio move --no-target-directory -- <src> <dest>` (rename; `gio rename` would read a name starting with `-` as an option), `gio mkdir -p`, `gio move`, `cp -a --no-clobber` (copy; `gio copy` refuses directories), `gio open`, `wl-copy --type text/uri-list` (Copy). Rename validation: not empty, no `/`, not `.`/`..`, no control characters, at most 255 bytes, never an existing name (a refused name keeps the field open with a red border and a short reason under it; a rename the file system refuses reopens the field with "Rename failed"). New Folder creates `untitled folder` (numbered) and opens its rename field. `.desktop` files are opened as text in the default text editor (`gio mime text/plain` then `gtk-launch`), never executed: the GNOME trust model (`metadata::trusted`) is not implemented.
7. Positions: `desktop-icons.json` in `$GRASSFIELD_STATE_HOME` (dev) or `$XDG_STATE_HOME/grassfield`, version 1, keyed by file name, directory 0700, file 0600, atomic write, debounced. Names that no longer exist are pruned (only once the folder model is ready, and not for names with an operation in flight). A rename keeps the position. A broken file is copied to `.bak`.
8. Drag and drop (real `wl_data_device` drags through Qt `Drag.Automatic`, mime `text/uri-list` plus the marker `application/x-grassfield-desktop-icons`): a drop on the desktop with the marker rearranges (group keeps its shape, occupied slots resolve to the nearest free one); other `text/uri-list` drops are copied into the desktop folder under unclaimed names and placed at the drop point; a drop on the Dock Trash tile (`shell/dock/Dock.qml`, highlighted while hovered) runs `gio trash`.
9. Setting `desktop.showIcons` (bool, default true; schema, defaults, `Settings.desktopShowIcons`, `Settings.setDesktopShowIcons`; the Settings app rule list in `apps/settings/qml/Store.js` mirrors it).

## Acceptance criteria
- `tests/shell/desktop_rename_focus`: the rename field is disabled, unfocused and cannot commit once the rename ended (`qs`, offscreen).
- `tests/unit/tst_desktopfocus.qml`: the safe-mode state machine (idle, menu, rename and the menu to rename hand-off), one test per user-visible rule: the desktop never takes the keyboard (click, hover, windows opening or closing, first click after a shell restart, pointer on another monitor), Esc / item / click outside on the menu release it without re-taking it, a click on an app window after the menu closes, menu > Rename hand-off order with no gap, rename commit, cancel and click outside (L0).
- Nested scenarios on GF-REF, with and without the plugin (foot probe writing typed lines to `.dev/probes/`, `scripts/nestctl activewindow -j`, input through `scripts/dev/keys.sh` and `pointer.sh`): (a) Esc on the menu then typing: no desktop action; (b) menu closed by a click on the foot, typing reaches the foot; (c) menu > Rename > new name > Return renames in `.dev/desktop-sandbox`, the foot receives nothing; (d) menu > Rename, click on the foot: cancelled, file unchanged, the foot receives the next typing; (e) desktop clicked, arrows, Return, F2, Ctrl+A, Ctrl+Backspace: nothing happens on the desktop, no file moves; (f) pointer on the other output: the menu still closes with Esc, a rename keeps the keyboard; plus menu > New Folder > name > Return (L1).
- `tests/unit/tst_desktopicons.qml`: blocked slots under widgets, top-right column-first layout, saved slots, moves, navigation, rename validation, unique names, positions parse/serialize/prune, URI lists, launcher parsing, folder resolution.
- Nested screenshots (`.dev/shots/`): icons, selection, rubber band, inline rename, both context menus, drag onto the Trash (`gio list trash://` shows the file; restored with `gio trash --restore`).

## Known limitations
- Keyboard safe mode: the desktop has no keyboard interaction (see "Keyboard safe mode (2026-10-17)"). A click outside the open menu or rename closes / cancels it and is consumed by that surface (an Exclusive layer takes the pointer too): it does not also focus the window under it; the window that Hyprland counts as active keeps (or gets back) the keyboard.
- The menu bar layer is `OnDemand` permanently (`shell/menubar/MenuBar.qml`, outside this module): it takes the keyboard when it maps and when the pointer moves over it.
- Icons appear on the first screen only. Positions are slots, so a smaller grid re-places icons.
- Drops from other applications always copy: Qt does not tell Shift (move) from the default action. Not exercised with a real foreign source (no DnD source app in the nested session); the drop path is the same code as the internal one.
- Get Info, Change Wallpaper and Use Stacks are omitted. No paste, no icon size or sort options, no mounted-volume icons.
- Because the surface takes the whole screen, windows that are unmapped leave the empty desktop owned by the icons surface, not the wallpaper (the wallpaper has no input of its own).

## Keyboard safe mode (2026-10-17)
Two fix attempts on the desktop's keyboard focus failed review (typed text landing in an app window, then the desktop keeping the keyboard after the menu closed and Return / Ctrl+A / Ctrl+Backspace acting on the selection while the user typed elsewhere). Owner decision: the desktop goes into a safe mode until a redesign on the macOS model (the desktop as an app, focus managed by Hyprland, the context menu attached to the desktop), which follows a separate research step.

Rules (implemented by `KeyboardFocus.js`, a pure state machine with the modes `idle`, `menu`, `rename`; hosted by `DesktopIcons.qml` and `IconsView.qml`):
1. The desktop surface (`grassfield-desktop-icons`) never holds the keyboard on its own: its keyboard interactivity is `None`, except `Exclusive` while a rename field is active. Hovering, pressing, windows opening or closing, workspace changes and the pointer on another monitor change nothing.
2. Context menu open: the menu window (`grassfield-icons-menu`) is `Exclusive` (arrows, Return, Esc). On close (Esc, an item, a click outside) it goes back to `None` and unmaps, and the desktop does not take the keyboard: Hyprland decides, as with a plain wallpaper.
3. Rename (menu > Rename, New Folder, a rename reopened after a file system failure): the rename surface becomes `Exclusive` BEFORE the menu window lets go. Hand-off: `commit` (desktop `Exclusive` and committing, the menu window still `Exclusive`), `map` (the commit is out, the menu window is `None` but still mapped so Hyprland has no reason to refocus another window), then the menu window unmaps once the desktop has the keyboard or two frames passed. New Folder keeps the menu window holding the keyboard until its rename field opens (or the folder creation fails). The rename ends on Return (commit), Esc, a click outside (the click lands on the Exclusive surface and cancels, never renames), or the field losing focus; then the surface goes back to `None`. The rename field is disabled and unfocused outside a rename (`tests/shell/desktop_rename_focus`).
4. All desktop keyboard handlers are gated off by `IconsView.desktopKeyboardNav: false` (`Keys.enabled`): no arrow navigation, no Return, Space (Glance), F2, Ctrl+A, Ctrl+Backspace or Esc on the desktop.

Works with the pointer: selection (click, Ctrl, Shift, rubber band), double click to open, drag and drop in and out, the context menus (including Rename and New Folder, typing in the rename field), Move to Trash from the menu.

Off until the redesign: every keyboard action on the desktop itself (arrows, Return, F2, Space / Glance, Ctrl+A, Ctrl+Backspace, Esc), the desktop re-taking the keyboard after a menu or a rename, B2-like logic (Hyprland's fallback focus after the active window closes) and the Glance lend, which only served the held-keyboard mode.

Dev: `scripts/dev/shell-run.sh` seeds `lock.idleMinutes: 0` in the dev config when the key is absent, so nested sessions never idle-lock.
