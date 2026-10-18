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
1. Surface: `DesktopIcons.qml` maps one layer-shell window per primary screen (the first screen; dev override `GRASSFIELD_DESKTOP_SCREEN=<output>`), namespace `grassfield-desktop-icons`, Background layer, created after the wallpaper (so above it) and below the Bottom-layer widgets surface (`DesktopWidgets.qml`, not touched). The window spans the screen and has no input mask: a click on empty desktop starts a rubber band and gives the desktop the keyboard (see "Keyboard focus" below). The widgets layer above keeps its own input. It reports the pointer to `PointerTracker` (the wallpaper below no longer sees it). Nothing animates or repaints on a timer.
2. Folder: `$GRASSFIELD_DESKTOP_DIR`; else, in a dev session (`GRASSFIELD_DEV=1`), `<state>/desktop-sandbox`; else `xdg-user-dir DESKTOP`; else `~/Desktop` (also when XDG answers `$HOME`). `scripts/dev/shell-run.sh` always passes `GRASSFIELD_DESKTOP_DIR` (default `.dev/desktop-sandbox`). Model: `Qt.labs.folderlistmodel` (hidden files are not shown). The folder is never created or modified except by explicit user actions below.
3. Grid (`IconsLogic.js`, pure): slot (col, row), col 0 right-most. Unplaced icons take the first free slot column-first from the top-right, in case-insensitive name order. Cell, margins and sizes are tokens (`desktopIcon*`); the grid avoids the menu bar and the Dock footprint.
4. Icons: theme icon from an extension map (fallback `text-x-generic`), images show a thumbnail with `sourceSize` capped at `desktopIconThumbnailMax`. A `.desktop` file shows its `Name` and `Icon` as plain text (parsed, never executed).
5. Interaction: click selects (Ctrl toggles, Shift adds; a press on an icon that is already part of a multi-selection keeps the selection for a group drag, and the release without drag then leaves that icon alone selected, as in macOS); rubber band on empty space; double click opens; icons can be dragged. Keyboard, active ONLY while the desktop surface holds the keyboard ("Keyboard focus" below): arrows move the selection, Return (or F2) renames the selected file, Ctrl or Meta+O opens the selection, Ctrl+Backspace moves it to the Trash, Ctrl+A selects all, Space shows Glance for the selection (`grassfield-preview --glance`, `shell/services/GlanceApp.qml`, dev override `GRASSFIELD_PREVIEW_CMD`, passed by `scripts/dev/shell-run.sh`; Space again closes it), Esc closes Glance, else clears the selection. The context menus (`IconMenu`, `PopupMenu`) are a `PopupWindow` anchored to the desktop surface with a keyboard grab (`IconsView.qml`): it draws above windows, takes the keyboard, and a click elsewhere dismisses it (the compositor swallows that click, as macOS).
   Rename: an in-surface `TextInput` (`DesktopIcon.qml`), light field (`color.fieldFill` at `desktopIcon.renameFillOpacity`) with dark text (`color.fieldText`, role "rename field text" in `tests/visual/contrast-roles.json`, gate A2) and an accent selection. Return commits (also an Enter), Esc cancels, a click elsewhere on the desktop, or the field losing the keyboard (a click on a window, the other output), commits as in macOS (a name that cannot be used cancels then; with Return it stays open with the reason). The field is `enabled` only while its icon is renaming, so a finished rename can never hand focus back to a hidden field, and `accepted` is ignored unless the field is visible (`tests/shell/desktop_rename_focus`).
   Widgets: slots whose cell overlaps a desktop widget tile of the same screen (`Widgets.desktop`) are not available to icons (`Logic.blockedSlots`); icons on such slots move to the next free slot. Widgets win: they never reserve cells, they only block them.
6. File operations, only on those user actions and always as one argv: `gio trash`, `gio move --no-target-directory -- <src> <dest>` (rename; `gio rename` would read a name starting with `-` as an option), `gio mkdir -p`, `gio move`, `cp -a --no-clobber` (copy; `gio copy` refuses directories), `gio open`, `wl-copy --type text/uri-list` (Copy). Rename validation: not empty, no `/`, not `.`/`..`, no control characters, at most 255 bytes, never an existing name (a refused name keeps the field open with a red border and a short reason under it; a rename the file system refuses reopens the field with "Rename failed"). New Folder creates `untitled folder` (numbered) and opens its rename field. `.desktop` files are opened as text in the default text editor (`gio mime text/plain` then `gtk-launch`), never executed: the GNOME trust model (`metadata::trusted`) is not implemented.
7. Positions: `desktop-icons.json` in `$GRASSFIELD_STATE_HOME` (dev) or `$XDG_STATE_HOME/grassfield`, version 1, keyed by file name, directory 0700, file 0600, atomic write, debounced. Names that no longer exist are pruned (only once the folder model is ready, and not for names with an operation in flight). A rename keeps the position. A broken file is copied to `.bak`.
8. Drag and drop (real `wl_data_device` drags through Qt `Drag.Automatic`, mime `text/uri-list` plus the marker `application/x-grassfield-desktop-icons`): a drop on the desktop with the marker rearranges (group keeps its shape, occupied slots resolve to the nearest free one); other `text/uri-list` drops are copied into the desktop folder under unclaimed names and placed at the drop point; a drop on the Dock Trash tile (`shell/dock/Dock.qml`, highlighted while hovered) runs `gio trash`.
9. Setting `desktop.showIcons` (bool, default true; schema, defaults, `Settings.desktopShowIcons`, `Settings.setDesktopShowIcons`; the Settings app rule list in `apps/settings/qml/Store.js` mirrors it).

## Acceptance criteria
- `tests/shell/desktop_rename_focus`: the rename field is disabled, unfocused and cannot commit once the rename ended (`qs`, offscreen).
- `tests/unit/tst_desktopfocus.qml`: the pure state machine of `KeyboardFocus.js` (idle, armed, held, menu), one test per user-visible rule: hover and window events never take the keyboard, a press arms it (kick), the actions are active only once the keyboard is granted, a timeout, a click on a window or the pointer leaving release it, the menu keeps the desktop OnDemand and the actions off, Esc / item give the keyboard back, an outside dismissal drops to None and re-arms.
- Nested scenarios on GF-REF, with and without the plugin (probe foot windows through `scripts/dev/isolated.sh`, typed keys appended to `.dev/probes/`, input through `scripts/dev/keys.sh` and `pointer.sh`): (a) hover then type: foot gets the keys; (b) click, arrows, Return, type, Return: the right file is renamed in `.dev/desktop-sandbox`; (c) click foot, type; (d) right-click an icon, Esc, Return, type: the desktop gets them, then a click on foot gives it the keyboard; (e) menu open, click on foot: menu closed, click swallowed, no action; (f) menu or rename active, click on the other output: closed / committed, no stale key; (g) Space opens Glance, Esc closes it; (h) 10x menu, Esc, type immediately (L1).
- `tests/unit/tst_desktopicons.qml`: blocked slots under widgets, top-right column-first layout, saved slots, moves, navigation, rename validation, unique names, positions parse/serialize/prune, URI lists, launcher parsing, folder resolution.
- Nested screenshots (`.dev/shots/`): icons, selection, rubber band, inline rename, both context menus, drag onto the Trash (`gio list trash://` shows the file; restored with `gio trash --restore`).

## Known limitations
- The menu bar layer is `OnDemand` permanently (`shell/menubar/MenuBar.qml`, outside this module): it takes the keyboard when it maps and when the pointer moves over it.
- Icons appear on the first screen only. Positions are slots, so a smaller grid re-places icons.
- Drops from other applications always copy: Qt does not tell Shift (move) from the default action. Not exercised with a real foreign source (no DnD source app in the nested session); the drop path is the same code as the internal one.
- Get Info, Change Wallpaper and Use Stacks are omitted. No paste, no icon size or sort options, no mounted-volume icons.
- Because the surface takes the whole screen, windows that are unmapped leave the empty desktop owned by the icons surface, not the wallpaper (the wallpaper has no input of its own).

## Keyboard focus (ADR-0012, owner decision 2026-10-17: the macOS model)
The desktop belongs to the shell like Finder belongs to macOS: clicking it activates it, hovering never does. Hyprland decides who holds the keyboard; the shell only reacts to its own surface (`KeyboardFocus.js`, pure, `tests/unit/tst_desktopfocus.qml`; host `DesktopIcons.qml`). Spike evidence (nested Hyprland 0.56.2, with and without the plugin, identical): `docs/decisions/ADR-0012-desktop-focus-model.md`.

Rules:
1. The desktop surface (`grassfield-desktop-icons`) has keyboard interactivity `None` until a left press on it; then `OnDemand` ("armed"). Hover, windows opening or closing and the pointer on another output change nothing. Hyprland gives an OnDemand surface the keyboard only at the next pointer motion, so the press also maps a transient 1x1 transparent Background surface (`grassfield-desktop-kicker`, keyboard None) for `Tokens.desktopIconFocusKickMs`: mapping and unmapping it makes Hyprland re-evaluate and grant the keyboard (measured 60 to 180 ms) without any motion. When the keyboard is not granted within `Tokens.desktopIconFocusArmMs` (the pointer is over a window), the surface goes back to `None` (never OnDemand while idle: a permanent OnDemand would take the keyboard on hover).
2. "Held" = the surface window is active (`Window.active`, wl_keyboard enter; `activeFocus` is not usable: `forceActiveFocus` sets it on an inactive window). Only then the desktop keyboard actions run (`IconsView.keysActive`). Losing the keyboard (Hyprland focused a window after a click on it) goes back to `None`.
3. The pointer leaving the surface (onto a window, the other output, the menu bar, the Dock, a widget) also goes back to `None`: Hyprland ignores a click on the window it already counts as active, so without this a desktop that had the keyboard would keep it after a click on that window. The keyboard returns to Hyprland's last window at once.
4. Context menu: a `PopupWindow` with `grabFocus`, anchored to the desktop surface; the surface stays OnDemand while it is open. Esc or an item closes it and the keyboard is back on the desktop (20 to 80 ms later). A click elsewhere (window, other output) dismisses it and is swallowed by the compositor; the keyboard also goes back to the desktop, even if the pointer is over a window, so after an outside dismissal the surface drops to `None` for one kick interval and arms again: it gets the keyboard back only if Hyprland finds the pointer on the bare desktop; otherwise the keyboard is with Hyprland's last window and typing goes there.
5. Rename and the actions: see "Interaction" above.

Works with the pointer regardless: selection, double click to open, drag and drop in and out, Move to Trash from the menu.

Residual limits (measured, not fixed):
- Keys typed within about 50 ms of the menu closing (Esc, an item) are dropped by the closing popup, never misdelivered: with `keys.sh` started right after the Esc, 2 to 8 of 10 reached the desktop; with 50 ms or more between, 10 of 10 (plugin and no plugin, 0 keys ever reached a foot).
- After an outside-dismissal click, or a pointer move onto a window, the keys go to Hyprland's last active window, not the desktop (deviation from macOS, where the click would keep Finder active). One click on the desktop gives it the keyboard again.
- Hyprland re-evaluates focus only on pointer motion events: a pointer that jumps from the menu straight onto a window without a single motion over the bare desktop (a virtual pointer does this; a real one does not) leaves the desktop holding the keyboard under that window until the pointer moves over the desktop again.
- While the desktop holds the keyboard the pointer must leave and re-enter its surface to be reported again; widgets, the menu bar and the Dock count as leaving.
- Ctrl/Meta+O (open) was not exercised in the nested session (it would start an application).

Dev: `scripts/dev/shell-run.sh` seeds `lock.idleMinutes: 0` in the dev config when the key is absent, so nested sessions never idle-lock.
