# Window tiling spec · compositor-engineer (plugin) + shell-engineer (shell) · owner brief 2026-10-27

Status: step 0, documentation only (ADR-0036, Proposed). Nothing below is built except what "Today" names. A requirement
marked (T<n>) waits for the owner decision T<n> of `docs/audits/tiling-2026-10-27/decisions.md`; it is written with the
recommended option and changes with the answer. The parity matrix (`docs/audits/tiling-2026-10-27/parity-matrix.md`,
rows M01-M56 and W01-W31) gives the source of each behaviour. UI names follow master-prompt §14: no Apple or Microsoft
feature name.

Today (main 68ee009, plugin 0.14.0): drag tiling for the plugin's titlebar (halves, quarters, fill, blurred preview), the
`tile(address, place)` verb, Window > Fill, Center, Move & Resize (halves, quarters, Return to Previous Size),
Super+Ctrl+arrows and Super+Ctrl+R, three settings. Requirements FR47-FR50 and FR56 of `docs/specs/compositor.md`; this
spec extends them and takes precedence where it is more precise.

## macOS reference behavior (from Apple Help and public captures, described in words; no Apple image committed)
- **Drag.** A window dragged by its title bar tiles when the pointer reaches the left or right edge of the screen (half),
  a corner (quarter) or the menu bar (fill: the whole desktop, the menu bar and the Dock stay). A preview (a rounded
  rectangle with a light outline over the target, inset by the margins) shows the place before the release. Holding ⌥
  while dragging shows the nearest tile at once, anywhere on the screen, and works even with the edge settings off. A
  tiled window dragged away takes back its untiled size under the pointer. A window placed by hand is never "restored".
  Double-clicking a window edge extends that side to the screen edge; ⌥-double-click extends the opposite side too, and on
  a corner fills the screen.
- **Green button.** Resting the pointer on it opens, after about a second, a glass popover with a tail toward the button:
  "Move & Resize" (Left, Right, Top, Bottom), "Fill & Arrange" (Fill, Left & Right, Left & Quarters, Quarters), then a
  "Full Screen ›" row (Entire Screen, Left of Screen, Right of Screen; an icon in front of the row in macOS 27). Each
  layout is a small window glyph; in the arrangements the window's own area is dark and the other windows' areas light.
  Holding ⌥ changes Fill to Center, the halves to quarters and the arrangements to their right-first forms. In full screen
  the popover offers Exit Full Screen. Measured on the owner's captures (macOS 26): 230 × 251 pt, radius 12, 26-pt glyphs
  on a 52-pt pitch.
- **Window menu.** Minimize, Zoom, Fill (⌃🌐F), Center (⌃🌐C), then Move & Resize › with three headed sections, Halves
  (Left, Right, Top, Bottom, ⌃🌐 arrows), Quarters (no keys), Arrange (Left & Right, Right & Left, Top & Bottom, Bottom &
  Top with ⌃⇧🌐 arrows, then Quarters), and Return to Previous Size (⌃🌐R), each item with its glyph; ⌥ turns the Arrange
  items into the "& Quarters" layouts (⌃⌥⇧🌐 arrows). Then Full Screen Tile ›. Arrangements take the window and the next
  windows in stacking order.
- **Resizing.** Two windows tiled side by side share their edge: a small handle in its middle resizes both; the edge
  above or below the handle resizes one. A window tiled next to a resized tiled window takes the space left.
- **Settings** (Desktop & Dock > Windows, macOS 26/27 labels): "Drag windows to left or right edge of screen to tile",
  "Drag windows to menu bar to fill screen", "Hold ⌥ key while dragging windows to tile", "Tiled windows have margins"
  (all on); "Window title bar double-click action": Fill, Zoom, Minimize, No Action (Zoom).
- **Edge cases.** A window whose minimum size is larger than its tile overlaps its neighbours; full-screen windows do not
  tile; tiling works inside the current Stage Manager set and on every Space and display; the tile area leaves out the
  visible menu bar and Dock.

## Windows 11 reference (features proposed in T1; described in words)
- A flyout of layouts (miniature screens) on the Maximize button and on Win+Z, more layouts on large screens (thirds,
  1/4-1/2-1/4) and stacked ones on portrait screens; after a zone is chosen, the other windows are offered as live
  thumbnails in each empty zone (keyboard: arrows, Enter, Esc); windows placed together form a group recalled from the
  taskbar, Task View and Alt+Tab; the edge between snapped windows resizes them together (a bar on hover, always on); a
  bar of layouts at the top of the screen during a drag.

## Purpose and non-goals
Purpose: place windows in tiles, layouts and groups with macOS 27's look and gestures and the Windows 11 features the
owner takes, through the compositor plugin, with nothing lost without it (C2).

Non-goals: Hyprland's tiled layouts (dwindle, SUPER+T) as part of Grassfield's tiles; a custom zone editor; layout
suggestions from app usage history (W05); browser tabs as suggestions (W13); tips (W06); Mission Control on a drag through
the top (M04, Overview) and a Desktop change on a held edge (M05, Desktops); restoring windows when an output comes back
(M55, W17; gate R3); tiling dialogs and sheets (M32); per-window xdg TILED states.

## Terms
- **Work area**: an output's box minus its reserved area (the menu bar's and the Dock's exclusive zones, none when they
  auto-hide), minus the Stages strip while Stages shows it.
- **Zone**: a rectangle of the work area given as fractions; **place**: a named zone (left, top-left, fill, left-third…).
- **Layout**: an ordered set of zones covering the work area (catalogue in tokens); **arrangement**: a layout filled with
  the window that asks and the next windows in stacking order.
- **Tile group**: windows placed together by one arrangement, layout or suggestion (T1d).
- **Box from before**: a window's floating box before its first tiling.
- **Frame**: the surface box plus the titlebar band (32 px above the surface for the plugin's titlebar, none for client
  chrome, ADR-0015).

## Functional requirements (numbered, testable)

### Engine and placement (step 1: `compositor/` and `ui/tokens/` only)
- **TL1** Work area as defined above, per output, recomputed when Hyprland's reserved area changes (`monitor.layoutChanged`)
  and when the Stages strip shows, hides or moves. Tiles never extend outside it.
- **TL2** Margins: with "Tiled windows have margins" on, `tiling.margin` (8) between the work area's edge and each frame,
  and between frames; off, frames touch each other and the work area edges. Changing the setting re-places every tiled
  window on every output (M39).
- **TL3** Frames, not surfaces, fill zones: the surface box is the zone minus the titlebar band. Sizes are whole pixels.
- **TL4** Places: left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, fill, center (today); left
  third, middle third, right third, left two thirds, right two thirds, and the quarter columns of the ultra-wide class
  (T1f). Center keeps the window's size (at most `tiling.centerMaxFraction` of the work area) in the middle.
- **TL5** Layout catalogue: token group `tiling.layouts`, zones as fractions, per output class (T1f: small, large,
  ultra-wide, portrait; class from the output's logical width and aspect), generated into the plugin and the shell by
  `ui/tools/gen-tokens.py` (`--check` fails on a stale copy).
- **TL6** Arrangements (M27, M28): Left & Right, Right & Left, Top & Bottom, Bottom & Top, Quarters, and Left, Right, Top,
  Bottom & Quarters, filled with the window that asks first, then the next windows in stacking order that are tileable,
  on the same output, on the same Desktop and, with Stages on, in the active stage. With fewer windows than zones, the
  empty zones stay empty (the window that asks still takes its zone). The windows placed form a tile group (T1d).
- **TL7** A half placed next to a tiled neighbour that already covers part of the other side takes the rest of the work
  area beside it, not an exact half (M44).
- **TL8** Size limits (M46-M48, W27): a window whose minimum is larger than its zone gets its minimum, aligned to the
  zone's edge on the work area's border so it stays on the output; in an arrangement the neighbours shrink to make room
  when their minimum allows, else the frames overlap. A maximum smaller than the zone: the window takes its maximum,
  centred in the zone. X11 resize increments round the size down. The engine applies the minimum itself, so Hyprland's
  commit clamp never recentres a tile.
- **TL9** Not tileable (the menu items and popover glyphs greyed, no drag preview, never a suggestion): windows with a
  parent (dialogs), fixed-size windows (minimum equals maximum on an axis), pinned, full screen or zoomed, on a special
  workspace, minimized, X11 override-redirect.
- **TL10** Box from before (FR49, today): remembered at the first tiling and kept through later tilings; a tiled window
  dragged away gets that size back under the pointer at the same relative place; Return to Previous Size puts it back
  (centred on the window's output when the old box lies off every output); forgotten when the window is moved or resized
  by anything else, closes, or the plugin unloads.
- **TL11** Output removed: Hyprland moves the windows to another output (it translates them, H22); the plugin then places
  each tiled window into the same zone of the output it landed on and keeps its group. Output added: nothing moves.
- **TL12** Full screen and zoom: a tiled window that enters full screen or zoom keeps its tile record and is placed back
  in its zone when it leaves (by Hyprland's own restore of the floating box; the plugin checks the box and re-applies the
  zone if the work area changed meanwhile).
- **TL13** Stages (ADR-0013): tiled windows are floating and belong to stages; a stage swap changes no geometry; a drop
  that tiles wins over a drop on the strip (today).
- **TL14** Minimize, hide, Move to Desktop: the tile record and the group survive; a restored window returns to its zone
  if it is free, else to its box from before.
- **TL15** State: the plugin keeps, per output, the tiled windows (address, place or layout zone, group id); a change posts
  the `tiling` notice; `hyprctl grassfield-tiling` returns the state (ADR-0007 rule: no event grows with the windows).

### Drags (step 2)
- **TL16** Every interactive move of a floating window tiles like the plugin's titlebar drag (M01, M17): Hyprland's own
  move started by an app (`xdg_toplevel.move`, client chrome) or by Super+drag is observed on each motion
  (`input.mouse.move` with `dragController()->mode() == move`) and tiled after Hyprland ended the drag (the FR56
  pattern). The same preview is drawn, by the decoration every window carries (hidden for client chrome), under the
  dragged window.
- **TL17** The preview appears after the pointer has rested in a zone for `tiling.previewDelay` (value measured in nested
  against the owner's captures; macOS shows a short delay, U); leaving the zone hides it at once; a release before the
  delay does not tile. With Alt held there is no delay.
- **TL18** Alt-drag (M06, setting "Hold Alt key while dragging windows to tile", `windows.tilingOptionDrag`, on): while Alt
  is held during a move, the zone is the nearest half, quarter or fill from the pointer's position in the work area (the
  work area split in thirds across and down: corners give quarters, side thirds halves, the top-middle third fill, the
  centre the half on the pointer's side), whatever the edge and menu-bar settings.
- **TL19** The plugin's titlebar drag snaps to other windows and to the work area edges as Hyprland's drag does (public
  `performSnap`, `general:snap` values), outside tile zones (M11).
- **TL20** Double-click on a window's resize border (M14-M15): that side extends to the work area edge (with the margin
  when margins are on); with Alt, the opposite side too; on a corner with Alt, the window fills the work area. The window
  is then tiled (it has a box from before).
- **TL21** Unchanged rules: an output edge shared with another output never tiles (the drag moves the window over); the
  corner band is `tiling.cornerBand` (96) along a free side edge; the edge distance is `tiling.edge` (4).

### Popover and Window menu (step 3, waits for the merge of PRs #8-#10)
- **TL22** Hover: the pointer resting on the zoom light for `tiling.hoverDelay` (about a second on macOS; measured in
  nested) makes the plugin post `tile-hover` (enter) with the window and the light's rectangle; leaving the light posts
  leave. The shell opens the popover (popup kind `tiling` of `qs.overlay`) below the light, its tail centred on it,
  flipped above or shifted sideways when the output has no room. It closes on Esc, a click outside, an action, the window
  closing or losing its tile eligibility, a capabilities change without the feature, and when the pointer has been
  outside both the light and the popover for `tiling.hoverDelay`.
- **TL23** Popover content (M19-M21, M23): "Move & Resize" (Left, Right, Top, Bottom), "Fill & Arrange" (Fill, Left &
  Right, Left & Quarters, Quarters), "Layouts" (T1a, the output's class, T1f), one "Move to <output name>" row per other
  output, then "Full Screen ›" (Entire Screen; Left of Screen and Right of Screen only with T4). With Alt held: Center
  instead of Fill, the quarters instead of the halves, Right & Left and Right & Quarters. In full screen: Exit Full Screen
  only. Glyphs not available for the window (TL9) are greyed.
- **TL24** Client chrome (M25): on windows tagged `grassfield-client-chrome` whose app is a Grassfield app, the plugin
  hit-tests the zoom light at its token position (ADR-0015 `WindowControls`) to post the same hover; spike first in step 3
  (full-screen and zoomed windows, right-to-left layouts). Third-party client chrome gets no popover.
- **TL25** Window menu (T0, `AppMenuModel.qml`, M26-M28): Minimize, Zoom, Fill, Center, —, Move & Resize ›, Full Screen
  Tile › (T4), —, Enter Full Screen, —, Move to Desktop ›, —, Bring All to Front, —, the windows. Move & Resize › has the
  headed sections Halves, Quarters, Arrange (with Quarters), then Return to Previous Size; each row has its glyph; Alt
  shows the "& Quarters" alternates in place. Shortcut texts come from the one table that mirrors `bindings.lua`.
- **TL26** Keyboard (T2, option A): Super+Ctrl+arrows halves, again from a half: the quarter (Up/Down from a side half,
  Left/Right from a top or bottom half), the same half again: the matching half of the next output in that direction;
  Super+Ctrl+Return Fill; Super+Ctrl+C Center; Super+Ctrl+R Return to Previous Size; Super+Ctrl+Shift+arrows the four
  arrangements; Super+Ctrl+Alt+Shift+arrows the "& Quarters" layouts; Super+Ctrl+Alt+Left/Right the next output; Super+Z
  opens the popover on the focused window with keyboard focus (arrows between glyphs and rows, Return, Esc; with Layouts,
  a number picks a layout and a second number a zone).

### Windows features (step 4, each only if the owner takes it)
- **TL27** Layouts (T1a, T1f): the popover's Layouts section shows the catalogue of the window's output class as miniature
  screens; hovering a zone highlights it; a click places the window in that zone and, with suggestions on, opens TL28 for
  the other zones; the layout's windows form a group.
- **TL28** Suggestions (T1c, option 2): after a layout or an arrangement chosen from the popover, the Window menu or the
  keys leaves zones empty, the shell shows in each empty zone, one zone at a time, live thumbnails (ScreencopyView) of the
  tileable windows of the same output, Desktop and stage, minimized ones included; a click or Return places the chosen
  window there and moves on to the next empty zone; Esc, a click outside or the window that asked losing its zone ends it.
  Nothing is shown when no window fits. Not after a plain edge drag.
- **TL29** Tile groups (T1d, option 1): a window brought forward from the Dock, the app switcher or the Overview brings its
  group forward (back to front in the group's stacking order, the chosen window in front); the Dock's app menu lists the
  app's groups ("Show Tile Group"); the Overview moves a group to another Desktop as one; a window leaves its group when
  it is moved or resized out of its zone, minimized windows stay members; a group of one dissolves.
- **TL30** Shared edge (T1e, option 1, M43, W18): between two windows of a group whose frames share an edge (margin
  between them included), the pointer over the middle `tiling.handleLength` of that edge shows a handle (resize cursor);
  dragging it moves the edge for every window of the group along it, within their minimum and maximum; outside the handle
  the edge resizes one window as usual. Spike first: the neighbours follow on each step of Hyprland's resize
  (`CWindow::m_events.resize` or the motion listener, then `setTargetGeom` and a warp), measured for configure storms and
  P3; if live following proves too slow, the neighbours follow at the release and show their app icon on the glass during
  the drag (Windows' placeholder).
- **TL31** Layout bar (T1b): not built with the recommended option. With option 2: during a move, the pointer in the
  top-centre third of the menu bar for `tiling.previewDelay` shows a glass bar of the layouts below the menu bar; the
  plugin hit-tests the zones the shell published for it (as the Stages strip does) and posts the hovered zone; the release
  on a zone places the window and opens TL28.

### Settings (step 5, waits for the merge of PRs #8-#10)
- **TL32** Desktop & Dock > Windows, in this order: "Drag windows to left or right edge of screen to tile"
  (`windows.tilingEdges`, on), "Drag windows to menu bar to fill screen" (`windows.tilingMenuBar`, on), "Hold Alt key
  while dragging windows to tile" (`windows.tilingOptionDrag`, on), "Tiled windows have margins" (`windows.tilingMargins`,
  on), then the switches of the features taken with the T3 names: "Show layouts when hovering over the green button"
  (`windows.tilingLayouts`, on), "Suggest windows to fill the rest of a layout" (`windows.tilingSuggestions`, on), "Bring
  tile groups forward together" (`windows.tilingGroups`, on). "Window title bar double-click action" gains Fill
  (`windows.titlebarDoubleClick` = `fill`). Each key is pushed with `config(...)` once the plugin advertises its feature;
  without the plugin the rows show the existing footnote and do nothing. The settings contract (ADR-0020) and the schema
  in `config/schema/` gain the keys in the same commit.

### Full Screen tile (step 6, only with T4)
- **TL33** Full Screen › Left of Screen / Right of Screen: a new Desktop right after the current one, the menu bar and the
  Dock hidden on it, the window in that half and suggestions (TL28) for the other half; a separator between the two that
  resizes both (double-click resets); dragging a window by its title bar to the other side swaps them; the menu bar and
  the Dock show when the pointer reaches their edge; Exit Full Screen returns both windows to their Desktop and boxes.

## Appearance (F1 strict, ADR-0024)
- Targets: geometry within ±1 pt of the owner's captures, tints within ±0.1, contrast A2, motion by tokens. Tokens only;
  the geometry constants of today (`kEdge`, `kCorner`, `kMargin`, `kCenterMaxFraction`) move to the token group `tiling`
  in step 1.
- Proposed tokens (values from the owner's captures where measured, else marked estimate until measured in nested):
  `tiling.popoverWidth` 230, `tiling.popoverRadius` 12, `tiling.popoverGlyph` 26, `tiling.popoverGlyphPitch` 52, section
  titles in the menu header style, `tiling.hoverDelay` (estimate 1000 ms), `tiling.previewDelay` (estimate, U),
  `tiling.margin` 8, `tiling.edge` 4, `tiling.cornerBand` 96, `tiling.centerMaxFraction` 0.9, `tiling.handleLength`
  (estimate, U), `tiling.layouts` (TL5).
- Popover: the glass of the "Menus, Search" class (it carries text: the A2 floor applies), rims per ADR-0024, tail toward
  the light, shadow of menus. Glyphs: the outline and the window's own area in the label colour, the other windows' areas
  in the secondary label colour; hover and keyboard focus: the accent fill with white glyphs (ADR-0024 "white on the
  accent"); disabled: the tertiary label colour.
- Light and dark appearances: popover, glyphs, suggestions overlay, handle and preview follow `Appearance.dark`; the
  preview keeps its tokens `titlebar.previewTint*` / `previewRim*` (FR48, FR53).
- Preview: the frosted pane of owner decision D-8 (not macOS's outline), corners at the window radius, inset by the
  margins.
- Suggestions overlay: the work area dimmed outside the empty zone, thumbnails fitted in the zone with the window's
  title below, accent focus ring; glass of the "Overview band" class.
- Reduce Transparency: opaque surfaces of the same class. Reduce Motion: window moves are instant (Hyprland `windowsMove`
  off, already pushed by the shell), overlays crossfade within `motion.reducedMax`.

## Motion
- Window moves into tiles: Hyprland's `windowsMove` leaf (today speed 3, curve `gfDecelerate`), values mirrored from the
  motion tokens in `config/hypr/grassfield/looknfeel.lua` and `shell/platform/Minimized.js motionLeaves`; compared with
  the owner's recordings in nested if they exist (U).
- Popover open and close, suggestion steps, handle and preview fades: `motion.fast` / `motion.normal` with
  `motion.curveStandard`. No duration or curve outside the tokens.

## Interfaces / contracts (proposed; payloads fixed in each step and recorded in ADR-0007's contract table then)
- **Plugin verbs (gfc/1, additive):** `tile(address, place)` with the TL4 places; `arrange(json)`
  `{"layout":"<catalogue id>","windows":["0x…",…],"output":"<name>"?}` (at most 4 windows, 4 KiB); `config` keys
  `tilingOptionDrag`, `tilingLayouts`, `tilingSuggestions`, `tilingGroups` and `titlebarDoubleClick` = `fill`.
- **Plugin events:** `tiling` notice `{gen, reason}` (bounded); `tile-hover` `{address, state: enter|leave, x, y, w, h}`.
- **Plugin reply:** `hyprctl grassfield-tiling`: per output the work area, the tiled windows (address, zone, group) and a
  pending suggestion.
- **Features:** `window-tiling` (today) plus one per capability (layouts and arrangements, hover, groups, shared edge),
  each advertised only when its listeners and verbs registered.
- **Shell IPC (`qs ipc`, for key bindings):** `windows tile <place>` (today), `windows arrange <layout>`, `windows
  tilePopover`, `windows nextOutput <direction>`; each listed in `docs/specs/security.md` in the step that adds it
  (`tests/security/ipc_inventory.sh`).
- **Settings keys:** TL32, in the settings contract (ADR-0020) and `config/schema/`.

## Dependencies (verified versions)
- Hyprland 0.56.2, commit efb50993: the internals of ADR-0036 and `docs/audits/tiling-2026-10-27/sources.md` (read in the
  sources; re-verify on every Hyprland update, the ABI check refuses a mismatched build).
- Quickshell 0.3.1 (overlay layer surfaces, ScreencopyView for the suggestions) and Qt 6.11.2: the qmltypes are checked in
  steps 3 and 4 on the owner's machine (not available in this container).

## Degraded behavior (plugin missing, unloaded, or a feature missing)
- No plugin: every window stays where it is; no tiling menu items, no popover, no suggestions, no groups, no handle; the
  keys do nothing; Settings shows the tiling rows with the "needs the Grassfield compositor extension" footnote; Hyprland's
  drags move windows as usual (C2).
- Unload during a drag, a popover or suggestions: the plugin removes its listeners and the preview, posts empty
  capabilities; the shell closes the popover and the overlay; windows keep their boxes; groups are forgotten.
- A missing feature (older plugin): the shell hides only what that feature serves.

## Automated tests · Manual verification steps
- **Unit (L0, gtest, `compositor/tests/TilingTest.cpp` grown):** work area with menu bar, Dock, Stages strip and margins;
  every place and layout on the four output classes; arrangements with 1 to 4 windows; neighbour-aware halves; minimum,
  maximum and increments; not-tileable classes; output removal; key composition (half → quarter → next output); drag zones
  with and without Alt; the token copies equal (`gen-tokens.py --check`).
- **Unit (L0, QML):** `tst_appmenumodel` (the full Window menu, alternates, greying); a pure popover model test (sections,
  Alt alternates, full screen, outputs); suggestion and group models.
- **Nested (L1, `tests/compositor/tiling.sh` grown; the integrator runs them, never on the owner's session):**
  1. step 1: arrange with 2, 3, 4 windows on GF-REF; a test client with a large minimum; margins toggled re-place; output
     removal with tiled windows; Stages on (area beside the strip); minimize and restore to the zone;
  2. step 2: client-chrome drag (Files, Chromium) tiles with the preview; Super+drag tiles; Alt-drag in the middle;
     double-click on an edge, Alt-double-click on a corner; the preview delay; unload in the middle of a drag;
  3. step 3: hover opens the popover (captures in both appearances, measured against the owner's gs-068-161, gs-069-175,
     gs-068-149); keyboard Super+Z, arrows, Return, Esc; Alt alternates; Move to <output> on two outputs; the Window menu
     capture against gs-020-039;
  4. step 4: layouts per class, suggestions with the keyboard, groups from the Dock, the switcher and the Overview, the
     shared-edge handle with live neighbours (frame times, P3);
  5. every step: C2 (`nested-up.sh --no-plugin`), C1 soak with tiling actions in the churn, Reduce Motion, 0 QML errors.
- **Owner (L2):** trackpad drags, a HiDPI or portrait output, the real Dock and switcher.

## Performance (gates affected)
- P3: popover and suggestions open within one frame budget; the shared-edge drag keeps ≥ 95 % of frames under 16.7 ms
  with two live neighbours; the neighbours are configured at most once per output refresh.
- C1: the soak gains tiling actions (arrange, drag to edges, popover open and close, shared-edge drags).

## Accessibility
- Gate A1: every action has a Window menu item; the popover and the suggestions are navigable with the keyboard and
  show a visible focus; every glyph has an accessible name ("Left", "Left & Quarters", "Move to <output name>") and role.
- Contrast A2 on the popover text and glyphs in both appearances at every transparency value up to 0.6.

## i18n
- Every string through `qsTr()`, English and French complete (gate I1); the T3 names; output names are shown as the
  system gives them.

## Refusals (with the reason; rows of the parity matrix)
- W05 layout suggestions from usage history, W13 browser tabs, W06 tips, W29 Start-menu pairs, W30 custom zone editor:
  outside both references' core or Windows-only integrations.
- W22 stretch to full height, W24 minimize others: covered by macOS gestures (⌥-double-click, Hide Others).
- M32 tiling dialogs and panels: they belong to their window (Hyprland centres them on it).
- M41 a Quick Settings tiling control: not verified on Apple's pages.
- T1b layout bar: refused with the recommended option (the menu bar keeps its macOS role).

## Known limitations (honest, user-visible gaps vs macOS)
- Third-party apps that draw their own title bar (Chromium, GTK header bars, Electron) get no popover on their green
  button; the Window menu, the keys and the drags work for them.
- Hyprland tells every xdg window it is tiled and maximized (TILED_* and MAXIMIZED states, H21), floating or not; no
  per-window change.
- X11 windows: their minimum comes from size hints and Hyprland's commit clamp does not apply to them.
- No per-move animation curve: every tile move uses the `windowsMove` animation.
- Windows do not return to an output when it is connected again (macOS 27 does).
- Windows tiled the Hyprland way (SUPER+T) are outside Grassfield's tiles, groups and popover.
- Full Screen tile only if T4 takes it; until then Full Screen is one window per Desktop.
- Without the plugin there is no tiling at all.
- Timings not published by Apple or Microsoft (hover delay, preview delay, animation curve) are estimates until measured
  in nested against the owner's material.
