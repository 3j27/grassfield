# widgets spec (contract `widgets/1`) · shell-engineer · widgets v1

## macOS reference behavior (described in words, no Apple images committed)
Widgets live below the notifications in Notification Center and can also sit on the desktop. They come in three sizes: small (square), medium (2x1) and large (2x2). "Edit Widgets" opens a gallery of the available widgets with a size choice and an add action; a widget is positioned by dragging it on the desktop; its context menu offers Remove and the sizes. Desktop widgets are dimmed and desaturated while a window has focus and show full color when the desktop is the active surface.

## Purpose and non-goals
Purpose: first-party widgets in the Notification Center and on the desktop, behind a versioned contract (`widgets/1`, semver, master-prompt 5.3) so that the set can grow without changing the host.
Non-goals for v1: loading third-party widgets, network access of any kind, per-widget settings, widget stacks, interactive widgets other than Now Playing transport, widgets on the lock screen, free (non-grid) positioning.

## The contract `widgets/1`
### Package
A widget is a QML component in `shell/widgets/builtin/<id>/` plus `manifest.json`:

| field | rule |
|---|---|
| `id` | `[a-z][a-z0-9]{0,31}`, unique, equals the directory name |
| `name` | English display name, the key of the `qsTr` title shown in the gallery |
| `version` | semver `MAJOR.MINOR.PATCH` of the widget |
| `sizes` | non-empty subset of `small`, `medium`, `large`, no duplicates |
| `contract` | exactly `widgets/1` |
| `permissions` | list of `media`, `battery`, `system` (may be empty). `network` is not a permission of `widgets/1` and a manifest that names it is invalid |

Permissions describe what data the widget reads; the host does not enforce them in v1 (all widgets are first-party and reviewed). They are shown to the user once third-party widgets exist.

### Registry
v1 loads ONLY the widgets listed in the static registry `shell/widgets/Registry.js` (manifests, mirrored from the `manifest.json` files; `tests/unit/tst_widgets.qml` fails if they differ) and `Registry.qml` (component per id). A placement whose id is not in the registry is dropped when `widgets.json` is read. Nothing is discovered from disk at run time.

### Host API (what the host gives a widget)
The widget's root item is a `WidgetBase` (`shell/widgets/WidgetBase.qml`); the host fills it into its tile and sets:
- `size` (`small|medium|large`), always one of the manifest's sizes; the widget lays out in its own `width`/`height` (the tile minus nothing: the widget applies `padding`);
- `active`: false while the widget is not shown (gallery closed, Center closed). A widget must stop timers, sampling and animations when `active` is false;
- appearance: `dark`, and the shared `Appearance` colors; `reduceMotion` (no decorative animation when true);
- tokens: the `Grassfield.Ui` `Tokens` singleton (spacing, type sizes, radii, the `widget*` tokens); no hard-coded colors, sizes or durations;
- `devSession`: true in the nested development session (`GRASSFIELD_DEV=1`).
Built-in widgets may additionally read the shell services they declared a permission for (`Media`, UPower). The size of the tile for a cell edge `c` and gap `g`: small `c x c`, medium `(2c+g) x c`, large `(2c+g) x (2c+g)`. The desktop uses `Tokens.widgetCell`/`widgetGap`; the Center uses half of its inner width.

### Lifecycle
Created by `WidgetHost` when its tile is shown (Center open, gallery row visible, desktop window mapped), destroyed when the tile goes away; a size change recreates the layout through the `size` property only (the component is kept). A widget that fails to load shows its name, never a blank tile. Widgets hold no state of their own beyond what they can recompute: v1 has no widget storage.

### What a widget must not do
- No network access (no `XMLHttpRequest` to the network, no WebSocket, no `curl`, no remote image URLs).
- No `Process` spawn, no file access except the documented `/proc` reads of the System widget through `FileView`.
- No timers or sampling while `active` is false; no polling faster than needed (clock: minute precision unless a seconds hand is shown; System: `Tokens.widgetSampleMs`).
- No actions that reach the user's real apps in a development session: Now Playing transport is disabled when `devSession` is true.
- Text from external sources (track titles) is shown as `Text.PlainText`; never `StyledText` or `RichText`.
- No hard-coded colors, sizes or durations; no Apple assets or trademark names.
- Every user-visible string goes through `qsTr`; interactive controls expose `Accessible.name` and `Accessible.role`.

### Third-party widgets (future, not in v1)
Loading code from outside the shell tree would run arbitrary QML inside the shell process, which owns the session lock and the notification service. Before it can exist: a separate process or a restricted engine without `Quickshell` imports, a permission prompt driven by `permissions`, signed or user-confirmed packages, a size/CPU budget, and an ADR plus `widgets/2`. `network` would be a new permission with an explicit per-widget host allow-list. None of this is implemented; v1 ignores unknown ids and never scans directories.

## Functional requirements
1. State: `widgets.json` in `$GRASSFIELD_STATE_HOME` (dev) else `$XDG_STATE_HOME/grassfield` (`~/.local/state/grassfield`). Directory 0700, file 0600, written atomically (temporary file and rename), debounced 300 ms after a change. Shape: `{"version": 1, "center": [{uid, id, size}], "desktop": [{uid, id, size, screen, col, row}]}`. On read: unknown ids and sizes the widget does not offer are dropped, duplicate or malformed `uid`s are regenerated, negative cells become 0 and cells above 1000 are clamped, at most 64 entries are kept per list (`Tokens.widgetMaxEntries`), a file larger than 256 KiB (`Tokens.widgetMaxFileBytes`) is rejected like an unparsable one, a file that is not a version 1 object is copied to `widgets.json.bak` and the state starts empty.
2. Notification Center: below the notifications (the same scrolling list), a "Widgets" heading when any exist, the tiles in a flow (two small per row, medium full width, large a square) and an "Edit Widgets" button. Right click, the Menu key or Shift+F10 on a focused tile opens its context menu (Small/Medium/Large with the current one checked, Remove Widget); Delete removes. The empty state "No Notifications" is the list header.
3. Gallery (`WidgetGallery.qml`, overlay inside the Center panel): every registered widget available on this machine (Battery is hidden without a battery) with a live preview, a size picker and two buttons: Add (to the Center) and Add to Desktop (to the output the Center is on, first free cell scanning from the right edge). Done or Esc closes it. Keyboard: Tab walks the size segments and buttons, Space or Return activates.
4. Desktop (`shell/desktop/DesktopWidgets.qml`): one small layer-shell surface per desktop widget (tile plus `Tokens.widgetSurfacePad` for the shadow, anchored top-left with margins), layer Bottom (above the wallpaper, below windows), namespace `grassfield-widgets`, exclusion mode Ignore, keyboard focus None. The input mask is the tile, so clicks anywhere else reach the layers and windows below. Grid: cell `Tokens.widgetCell`, gap `Tokens.widgetGap`, margin `Tokens.widgetDesktopMargin` from the screen edges, below the menu bar and above the height the Dock reserves (shelf, indicator row, bottom margin; reserved even when the Dock autohides). Drag (left button) moves a tile: while it is dragged its surface grows to the whole screen with a full-window input region (so a fast drag never outruns the mask) and shrinks again on release; on release the tile snaps to the nearest cell and, when that cell is taken, to the nearest free one; the result is saved. Right click opens the context menu in a separate Overlay window (`grassfield-widgets-menu`) that takes the keyboard exclusively while open (arrows, Return, Esc) and closes on any click outside. Resizing re-checks collisions. Off-grid or overlapping placements (a file edited by hand, a smaller screen) are moved to the nearest free cell when the file is read and whenever the screen's grid changes (a widget with no room left is dropped); nothing off the grid is shown or sampled. A widget whose tile is fully covered by one window of the workspace shown on that screen (fullscreen, maximized or tiled over it) has its surface hidden and `active` false. Coverage is re-read on Hyprland events (`openwindow`, `closewindow`, `movewindowv2`, `workspacev2`, `changefloatingmode`); Hyprland emits nothing when a floating window is moved or resized, so while a widget of the screen is hidden, pointer motion over the desktop (`PointerTracker`) triggers a debounced (300 ms) re-read. Desktop icons never overlap a widget tile (see desktop.md).
5. Dim: while a window has focus on that screen (`Compositor.focusedToplevel` set and the focused monitor), the desktop tiles are desaturated (`widgetDimSaturation`) and darkened (`widgetDimBrightness`) over `widgetDimMs` (instant with Reduce Motion). A click on a tile makes the desktop active (full color) until the focus changes to another window or `widgetActiveMs` passes without the pointer over a widget.
6. Built-in widgets, real data only: Clock (small digital; medium and large add an analog face drawn in QML; the seconds hand ticks only while visible), Calendar (today's day; month grid with today highlighted, first weekday from the locale), Battery (UPower display device; "No Battery" when absent; hidden from the gallery then), Now Playing (MPRIS active player, "Not Playing" otherwise; medium has previous/play-pause/next, disabled in a development session), System (CPU from `/proc/stat` deltas every 2 s and memory from `/proc/meminfo` every 8 s through `FileView`, one shared sampler for all System widgets, only while one is `active`; values are whole percents and the gauges are not animated). Now Playing art is shown only for `file://` and size-capped `data:image/` URLs (`ArtUrl.js`); any other URL a player names, http(s) included, is ignored and the placeholder is shown.

## Acceptance criteria
- `tests/unit/tst_widgets.qml` (L0): registry validity and equality with the manifest files, manifest rejections (including `network`), placement persistence round trip, unknown ids and sizes dropped, malformed files, grid size, footprints, snapping and clamping, collisions and nearest free cell, entry cap and oversized/duplicate-uid files, re-fitting of off-grid and overlapping entries, grid rows at 768/1080/2160-high screens with the menu bar and Dock reserve, the art URL filter, month lengths independent of the local zone (DST at midnight), calendar month grid for Sunday and Monday week start and 4/5/6-row months, `/proc` parsers.
- Nested screenshots (L2): Center with widgets, gallery, widget menu, desktop widgets full color and dimmed with a `foot` window focused, drag and persistence across a shell restart.

## Interfaces / contracts (versions)
Contract `widgets/1` (above). Reads `Compositor` (`qs.platform`) for the focused toplevel and monitor, `Media`, UPower, `Appearance`/`Tokens`. State file `widgets.json` version 1. No IPC target, no `grassfield.json` key.

## Dependencies (verified versions)
Quickshell 0.3.1: `PanelWindow`, `WlrLayershell`, `Region` mask, `Variants.instances`, `ScriptModel`, `FileView`, `SystemClock`, `Process`, UPower, MPRIS. Qt 6.11.2: `QtQuick.Effects.MultiEffect`, `QtQuick.Shapes`, `DragHandler`.

## Degraded behavior
No battery: Battery hidden from the gallery; a placed one shows "No Battery". No player: "Not Playing". `/proc` unreadable: the System widget keeps its placeholder. Unwritable state directory: placements work for the session and are not saved. Compositor focus unknown: widgets stay in full color.

## Automated tests · Manual verification steps
`scripts/dev/test.sh`, `scripts/dev/qmllint.sh`. Manual (nested): `scripts/dev/nested-up.sh`, open the Center (`qs ipc call notifications toggleCenter`), Edit Widgets, add; seed `.dev/state/widgets.json` for desktop placements; drag with `scripts/dev/pointer.sh output GF-REF abs X Y down ... up`; start `foot` on the nested socket and compare screenshots.

## Performance · Accessibility · i18n
P2: with 5 widgets (3 desktop, 2 in the Center) RSS grew by about 32 MB with the Center closed and 46 MB with it open (nested, empty 330 MB). A closed Center holds no widget items; a desktop window exists only on screens with desktop widgets. Sampling timers run only while `active`. Accessibility: tiles are `Accessible.Grouping` with name, size and a hint for the Menu key; menu, gallery, size segments and buttons have names and roles and are reachable with Tab. All strings use `qsTr`; external text is `PlainText`.

## Known limitations
- Desktop widget moving is pointer only (the Bottom layer cannot take the keyboard without stealing it from windows); add, remove and resize work from the keyboard through the gallery and the Center menus, and the desktop menu is keyboard operable once opened.
- "Desktop is active" cannot be detected when the user clicks the wallpaper (Hyprland keeps the window focused); only clicks on widgets and a focus change reveal full color, then it times out.
- Per-screen grids are independent; changing the screen resolution re-fits the placements to the nearest free cell (and drops one that has no room).
- Coverage is geometric: a translucent window over a widget still counts as covering it.
- The Battery widget was not visually verified with real data (the development machine has no battery); its "No Battery" state was.
- Desktop tiles have no blur behind them (the context menu and gallery are plain tinted surfaces).

## Changelog
### widgets/1
- Now Playing art URLs are filtered (`file://` and capped `data:image/` only); no widget can make the shell download a remote image.
- Desktop widgets: one small layer surface per widget instead of a full-screen one; surfaces hidden and widgets inactive when covered by a window; gauges no longer animate; one shared System sampler.
- `widgets.json`: entry cap, size cap, linear parsing, overlapping and off-grid desktop entries re-placed on load and on grid change.
- Grid excludes the menu bar and the Dock's reserved height.
- Calendar month lengths use UTC date math (correct in zones with DST at midnight).
- Tokens `widgetLiftScale`, `widgetClockFaceRatio`, `widgetDateColumnRatio`, `widgetSurfacePad`, `widgetMaxEntries`, `widgetMaxFileBytes` replace literals.
