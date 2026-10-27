# ADR-0036: Window tiling: tiles of floating windows placed by the plugin, chrome drawn by the shell
Status: Proposed (owner brief 2026-10-27, step 0: docs only; the owner answered the decisions T1-T6, then T2a and T2b, of
`docs/audits/tiling-2026-10-27/decisions.md` on 2026-10-27, verbatim below; opus review of 0b6f614 FAIL, fixed in this
revision, counter-review pending) ·
Date: 2026-10-27 · Decider: owner · Number: 0036 (0033 Software Update, 0034 clipboard, 0035 dialogs are taken by open
work)

Amends ADR-0002 (window behaviour): windows stay floating-first, and Grassfield now arranges them in tiles, layouts and
tile groups. Removes "tiled windows" from the non-goals of `docs/specs/compositor.md`. Spec: `docs/specs/tiling.md`.
Parity matrix and sources: `docs/audits/tiling-2026-10-27/`.

## Context
**Owner brief (2026-10-27).** Window tiling taken far: the look and gestures of macOS 27 (drag to the edges, the
green-button popover, Window > Move & Resize) with the power of Windows 11 (a layout grid, suggestions to fill the rest of
a layout, groups, a shared edge). No Apple or Microsoft name in the UI.

**What main 68ee009 already does** (plugin 0.14.0, `docs/specs/compositor.md` FR47-FR50, FR56):
- A titlebar drag by the plugin's own titlebar tiles at a free left or right edge (halves), near the top or bottom of
  that edge (quarters) and on the menu bar (fill). A blurred preview shows the place (FR48, owner decision D-8). A tiled
  window dragged away gets its size from before back (FR49).
- `hl.plugin.grassfield.tile(address, place)` (feature `window-tiling`, ADR-0007) serves Window > Fill, Center and
  Move & Resize (halves, quarters, Return to Previous Size) and the keys Super+Ctrl+arrows and Super+Ctrl+R.
- Settings: `windows.tilingEdges`, `windows.tilingMenuBar`, `windows.tilingMargins` (all on).
- Pure logic `compositor/src/core/Tiling.*` (unit tests `TilingTest.cpp`), glue `compositor/src/Tiling.*`, nested test
  `tests/compositor/tiling.sh`.

**Gaps found while reading main** (detailed in the parity matrix):
- Only the plugin's titlebar drag tiles. Windows with client chrome (ADR-0015: Grassfield's Files, Settings and Preview;
  Chromium, Obsidian, Evince, Nautilus) move by Hyprland's own interactive move (`xdg_toplevel.move`), which never tiles.
- One window at a time: no arrangement of several windows (macOS Arrange), no layout with thirds, no groups, no shared
  edge (macOS resizes two side-by-side tiled windows together from a handle on their shared edge, Windows from a divider).
- No popover on the green light, no Option-drag, no Full Screen tile, no "Move to <display>".
- Labels follow macOS 15. macOS 26 and 27 renamed the first setting ("Drag windows to left or right edge of screen to
  tile") and added "Hold ⌥ key while dragging windows to tile" (Apple Help, research notes in the audit).

**Hyprland 0.56.2 facts** (read in the v0.56.2 sources, commit efb50993, the tree that ships as `/usr/include/hyprland`;
paths relative to `src/`; details and the full list in `docs/audits/tiling-2026-10-27/sources.md`):
- Layouts: a plugin can register a tiled algorithm (`HyprlandAPI::addTiledAlgo`, plugins/PluginAPI.hpp:214) chosen per
  workspace by the `layout` workspace rule or `general:layout` (layout/supplementary/WorkspaceAlgoMatcher.cpp:104-109).
  `addFloatingAlgo` (:215) registers a name but nothing selects it: every workspace gets the default floating algorithm
  (WorkspaceAlgoMatcher.cpp:111-113). `CAlgorithm::updateFloatingAlgo` exists without any caller in the tree
  (layout/algorithm/Algorithm.cpp:170). `addLayout` is deprecated and returns false.
- Stacking: Hyprland draws every non-floating (tiled) window of a workspace before its floating windows
  (render/Renderer.cpp:455-510, "floating on top"). A window in a Hyprland tiled layout can never be in front of a
  floating window.
- Geometry: `CLayoutManager::setTargetGeom` places floating targets only (layout/LayoutManager.cpp:83-88), does not clamp
  and applies no gap; the move animates with the `windowsMove` animation of the config, the client is configured with the
  goal size at once. A floating xdg window is clamped to its protocol minimum and maximum at its next commit and recentred
  (desktop/view/Window.cpp:2741-2747, :1277-1289); X11 windows and rule minimums are not clamped there.
- Constraints: `CWindow::minSize()` / `maxSize()` return a window rule's value when one is set, in place of the client's
  (a `min_size` rule replaces the protocol minimum, it does not add to it), else the X11 size hints or the xdg min/max
  (Window.cpp:2885-2922). The commit clamp above uses the protocol values only, so a tile must respect the larger of the
  rule and the protocol minimum. Hyprland itself floats windows with a parent, with min == max on either axis (xdg) or
  both (X11), and X11 windows of the dialog, splash, toolbar, utility, tooltip, menu and dock types, modal or transient
  ones (managers/XWaylandManager.cpp:110-147).
- Work area: `CMonitor::logicalBoxMinusReserved()` (output/Monitor.cpp:1772) follows layer-shell exclusive zones (menu
  bar, Dock): `arrangeLayersForMonitor` updates the reserved area and calls `invalidateMonitorGeometries`
  (render/Renderer.cpp:2673-2700) without any bus event; `monitor.layoutChanged` is emitted only on output arrangement,
  mode and monitor-rule changes (state/MonitorLayoutController.cpp:70, output/Monitor.cpp:1399,
  config/shared/monitor/MonitorRuleManager.cpp:204). Gaps (`gaps_out`, `float_gaps`) apply only to Hyprland's own
  placement, never to `setTargetGeom` (layout/space/Space.cpp:77-107).
- Drags: Hyprland's interactive move and resize run in `CDragStateController::mouseMove`
  (layout/supplementary/DragController.cpp:298-455). The event bus emits `input.mouse.move` before each step
  (managers/input/InputManager.cpp:269, :446) and has no drag begin or end event; `dragController()->mode()` and
  `target()` are public, the drag's start position (`m_beginDragPositionXY`) is private
  (layout/supplementary/DragController.hpp:40-57), so a box set during Hyprland's drag is overwritten by the next step. A
  floating resize step never calls an algorithm (DragController.cpp:375-433); a tiled one calls the tiled algorithm's
  `resizeTarget` (:434-436). The plugin already ends Hyprland's drags this way (FR56, TopClamp) and restarts one from a new
  box for client chrome (`endDragTarget`, `setTargetGeom`, `beginDragTarget`, compositor/src/ClientChrome.cpp:113-116).
- Native groups (`CGroup`) are tabbed stacks sharing one box with one visible member (desktop/view/Group.cpp:327-341):
  not side-by-side groups.
- xdg states: every toplevel gets TILED_LEFT/RIGHT/TOP/BOTTOM at creation and MAXIMIZED at first map, floating or not, and
  never loses them (protocols/XDGShell.cpp:176-181, :529-531). No API changes them per window.
- Monitors: when an output goes away, its floating windows are translated to the backup output, never resized
  (state/WorkspacePlacementController.cpp:307-311).
- Rendering inside the compositor is proven: the tiling preview is a blurred `CRectPassElement` drawn from the titlebar
  decoration, between the dragged window and the windows behind it (compositor/src/Titlebar.cpp:614-626).

**Constraints.** R13 and gates C1-C3 (the plugin is optional, degrades with nothing lost); ADR-0007 (gfc/1 additive, no
event that grows with the number of windows, untrusted arguments); ADR-0021 (raw Hyprland events through the shell's
platform layer only); ADR-0024 (macOS 27 structure, macOS 26 glass, tokens only, A2); master-prompt §14 (neutral names).

## Options
1. **Floating windows placed by the plugin (extend today's model).** Every window stays a Hyprland floating window. A pure
   geometry engine in the plugin computes tiles, layouts and groups; the glue applies them with `setTargetGeom` and keeps
   the tile state (zone, group, the box from before). The shell draws the interactive chrome (popover, layout grid, fill
   suggestions) and sends requests.
   - Pros: windows keep macOS stacking (a tiled window comes to the front like any other); Stages (ADR-0013), Overview,
     minimize and hide already handle floating windows; without the plugin every window simply stays where it is;
     builds on code that passed R13 and nested tests.
   - Cons: shared-edge resize needs its own per-step mechanism (listener on Hyprland's drag); the commit clamp may resize a
     window the engine placed below its minimum, so the engine must apply the minimum first.
2. **A Grassfield tiled algorithm** (`addTiledAlgo`, selected per workspace). Tiled windows become Hyprland tiled
   windows; the algorithm gets `resizeTarget` on every drag step, so a shared edge is native.
   - Cons: tiled windows are always drawn under every floating window (Renderer.cpp:455-510), so a tiled window could never
     be brought in front of a floating one; one tiled algorithm per workspace; Stages excludes tiled windows (stages.md
     ST9) and Overview, minimize and the titlebar drag would need a second path; dragging a tiled window floats it for the
     drag; unloading the plugin hands every tiled window to dwindle, which rearranges the whole desktop (no window is lost,
     but the user's arrangement is).
3. **Replace the floating algorithm on each workspace** (`updateFloatingAlgo`). No supported registration path, no caller
   in the tree; Hyprland's drag steps, X11 configure requests and commit clamps go around the algorithm anyway; unload must
   restore every workspace by hand. Fragile on every Hyprland update.
4. **Shell only** (Hyprland dispatchers through the platform layer, no plugin). No drag preview, no drag hooks, no shared
   edge, no hover on the green light. Fails the brief; kept only as the reason why the degraded mode offers no tiling.

## Decision (proposed)
**Option 1.** Tiling stays a placement of floating windows, as on macOS, where a tiled window is an ordinary window that
any other window can cover. The compositor owns the truth that must change synchronously with input (drags, hover,
geometry, the state of tiles and groups); the shell owns everything drawn as UI chrome with text, glass and keyboard
navigation.

### Plugin (`compositor/`)
- **Geometry engine** (pure, `core/Tiling.*` grown into a small module, unit-tested): the layout catalogue, the work area
  of an output, margins, the titlebar band (32 px for plugin chrome, 0 for client chrome), minimum and maximum sizes,
  arrangements of 1 to 4 windows, shared edges inside a group, drag zones (edges, corners, menu bar, Option-drag),
  keyboard moves (next zone, next output), the box from before.
- **Placement and state** (glue): a tile record per window (zone, frame, box from before, group, output) applied with
  `setTargetGeom` (animated by Hyprland's `windowsMove`) and driven by one state machine, `docs/specs/tiling.md` TL10:
  Free, Tiled, Moving, Resizing, Suspended. A user's resize (a border, the shared-edge handle) keeps the record and the
  group, and updates the frame; full screen, zoom, minimize and hide suspend it; a drag away, a release elsewhere, a change
  made by anything the plugin does not observe (an app's X11 configure, a keyboard dispatcher, a rule), closing, unmapping
  and unloading end it. It replaces FR49's "moved or resized since its tiling" rule.
- **Drags**: the plugin's own titlebar drag (today) and, new, Hyprland's interactive move of any floating window (client
  chrome, Super+drag), observed through `input.mouse.move` and `dragController()` with the release handled after Hyprland
  ended the drag (the FR56 pattern). Both draw the same preview. A tiled window dragged away by Hyprland's move takes back
  its size from before under the pointer by ending Hyprland's drag and beginning it again from that box, as client chrome
  does after a zoom. At the release a pending tile wins over the top clamp (FR56): the tile lies below the menu bar and the
  clamp leaves a window the release has just tiled alone.
- **Shared edge**: during Hyprland's resize of a tiled window that shares an edge in its group, the plugin moves the
  neighbour's edge on each step (the dragged window's `m_events.resize`, or the motion listener, then `setTargetGeom` and a
  warp of the neighbour). Spike first (step 4), measured against configure storms.
- **Hover on the green light**: the plugin titlebar reports the pointer resting on the zoom light (enter after the
  token delay, leave) with the light's rectangle, so the shell can open the popover. On Grassfield's client-chrome apps
  the plugin hit-tests the light at its token position (ADR-0015 `WindowControls`), no app change; spike in step 3.
  Third-party client chrome gets no popover (known limitation).

### Shell (`shell/`)
- **Popover** on the green light (macOS: Move & Resize, Fill & Arrange, Full Screen ›, plus the Layouts section, owner
  decision T1a): an overlay popup kind like the menus (`qs.overlay`), keyboard-reachable, glass per ADR-0024.
- **Window menu** (T0, `AppMenuModel.qml`): the full macOS 27 Move & Resize submenu (Halves, Quarters, Arrange, Return to
  Previous Size), Fill, Center, Full Screen Tile › (decision T4), Move to <display>.
- **Keys** (T2 option A with T2a and T2b): Super+Ctrl+arrows halves (always, as macOS), Super+Ctrl+U/I/J/K quarters by key
  position, Super+Ctrl+Return Fill, Super+Ctrl+C Center, Super+Ctrl+R Return to Previous Size, Super+Ctrl+Shift+arrows and
  Super+Ctrl+Alt+Shift+arrows the arrangements, Super+Ctrl+L the popover, Super+Ctrl+Alt+Left/Right the next output.
  Super+Z stays unused (Super plays Command: ⌘Z).
- **Session lock**: the popover, the suggestions overlay, the handle and every new `windows` IPC function ask
  `SessionState.refuses` first and close when the lock engages; `docs/specs/security.md` ("Nothing opens over the lock")
  names them as planned and lists each one with the step that adds it (tiling.md TL34).
- **Windows features taken by the owner (T1)**: the Layouts section of the popover (a catalogue per output class), the
  suggestions overlay (after a layout or an arrangement, not after a plain edge drag), tile groups in the Dock's app menu,
  the app switcher and the Overview, the shared-edge handle (always on). The layout bar at the top of the screen is not
  taken: the menu bar keeps its macOS role.
- **Settings > Desktop & Dock > Windows**: the macOS 27 switches and the switches of the Windows features taken.
- Everything reaches the plugin through `shell/platform/Compositor.qml` and `Minimized.js` (`isPluginVerb`), never through
  raw `hyprctl`.

### IPC (gfc/1, additive; exact payloads fixed in step 1 and recorded in ADR-0007's contract table then)
- Verbs: `tile(address, place)` keeps its signature and gains places (thirds, two thirds, the macOS arrange places);
  `arrange(json)`: a catalogue layout id and up to 4 window addresses in zone order (the first is the window that asked),
  an optional output; `config` keys for each new setting. Strict validation as today: catalogue ids only, addresses
  compared with live windows, at most 4 KiB.
- Events: `tiling` is a change notice `{gen, reason}` (bounded, under Hyprland's 1024-byte socket2 limit); the state
  (tiles and groups per output, a pending suggestion) is the reply of `hyprctl grassfield-tiling`, as Stages does
  (ADR-0007 amendment 2026-10-24). `tile-hover` `{address, state, x, y, w, h}` for the green light. No titles, no window
  contents.
- Features advertised separately, so the shell degrades per feature: `window-tiling` (today), plus one feature per new
  capability (layouts, hover, groups, shared edge), each only when its listeners and verbs registered.

### Layout catalogue
One source of truth for the plugin's geometry and the shell's drawings: the layouts (zones as fractions of the work area,
per class of output aspect) live in `ui/tokens/tokens.json` and are generated into `compositor/src/core/ThemeTokens.hpp`
and `Tokens.qml` by `ui/tools/gen-tokens.py` (`--check` in `just check-shell` already fails on a stale header).

### Work area, sizes, transients
- Work area, read when a placement is computed and not followed afterwards: the output minus its reserved area at that
  moment (menu bar and Dock exclusive zones; all of it when they auto-hide), minus the Stages strip column whenever Stages
  is on (shown or hidden: the strip hides when a window overlaps it, so following its visibility would make tiles grow
  over it and hide it again), minus the margins when "Tiled windows have margins" is on. Tiled windows are re-placed only
  when the margins setting changes and when their output goes away; a Dock that moves, grows, shrinks or hides moves no
  tile (Hyprland emits no event for a reserved-area change anyway).
- Rounding: zones are computed in logical coordinates and every edge is snapped to the output's device pixels
  (`round(v × scale) / scale`); sizes are differences of snapped edges, so adjacent tiles share one device-pixel edge at
  fractional scales.
- A zone smaller than a window's minimum: the window gets its minimum, aligned to the zone's outer edge so it stays on the
  output; in an arrangement the neighbours shrink to make room when their own minimum allows, else the windows overlap
  (macOS does the same, Apple's developer guidance). A maximum smaller than the zone: the window takes its maximum, centred
  in its zone. The minimum is the larger of the rule's and the client's (xdg); the engine applies it itself so the commit
  clamp never recentres a tile.
- Not tileable (menu items greyed, no preview, no suggestion): windows with a parent (dialogs), fixed-size windows
  (min == max), X11 windows Hyprland floats by type or as modal or transient, X11 override-redirect, Glance, pinned,
  full-screen and zoomed windows, windows on a special workspace.
- xdg TILED_* and MAXIMIZED stay as Hyprland sets them (no API to change them; changing them per window is out of scope).

### Monitors, Desktops, full screen, Stages, Overview
- Per output; an edge shared with another output never tiles (today). An output removed: Hyprland translates its windows
  to the backup output; the plugin then re-places the tiled ones into the same zone of the output they landed on and keeps
  their groups. An output added: nothing moves (macOS 27's return of windows on reconnect is not reproduced in step 1).
- A tiled window entering full screen or zoom is suspended (TL10) and finds its tile again when it exits.
- Full Screen tile (two windows sharing a full-screen Desktop, macOS Split View): its own step 6 after the others (owner
  decision T4: a new Desktop, the menu bar hidden, two tiles and a separator). The green light keeps ADR-0002's click
  (Zoom) until then (T5).
- Stages: tiled windows are floating, so they belong to stages; tiling uses the active stage's windows only and the work
  area beside the strip; a stage swap changes no geometry (ADR-0013). The rule "tiling at the screen edge wins over a drop
  on the strip" stays.
- Overview transforms windows without changing their geometry: tiles and groups are untouched.
- Minimize and hide suspend the tile record; restore returns the window to its zone when it is free, else to its box
  from before.

### Motion
Window moves use Hyprland's `windowsMove` leaf, whose values mirror the motion tokens (`config/hypr/grassfield/looknfeel.lua`
and `Minimized.js motionLeaves`); Reduce Motion already disables it (moves become instant). The preview and the shell's
overlays use the motion tokens; no duration or curve is hardcoded. The layout API has no per-move duration; none is needed.

### Degraded mode (C2)
Without the plugin, or when it unloads: every window stays at its current box (nothing is moved, nothing is lost); the
shell drops the tiling items, the popover, the overlays and the tiling switches' effect (Settings shows them with the
existing "needs the Grassfield compositor extension" footnote); the keys do nothing; Hyprland's own drags move windows as
usual. The unload posts empty capabilities after removing every listener and closing the preview (ADR-0007).

### Order of the steps (one pull request each, after the PASS of step 0; confirmed by the owner, T6)
1. Geometry engine and placement (compositor only): catalogue, `arrange`, state reply and notice, sizes, work area with
   the Stages strip, output removal, unit tests, nested `tiling.sh` extended, C1 soak, C2.
2. Drags: client-chrome drags through Hyprland's move, Option-drag, edge double-clicks, the preview per ADR-0024, the
   macOS 26/27 drag rules.
3. Popover on the green light and the full Window menu (shell + the plugin's hover event), keyboard (T2, T2a, T2b) and
   mouse.
4. The Windows 11 features taken (Layouts section, suggestions, tile groups, shared edge).
5. Settings > Desktop & Dock > Windows.
6. Full Screen tile (T4).
Step 1 touches only `compositor/` and `ui/tokens/`; steps 3 to 6 touch the shell, Settings or `config/hypr` and wait until
the integrator has merged the open Settings pull requests (#8, #9, #10), as the owner asked.

## Owner decisions (2026-10-27, verbatim)
Asked in the step 0 session as questions with options, written in French; the owner's answer is the option chosen, quoted
word for word as the session received it. T1a and T1f were one question; T2a and T2b were asked after the opus review of
0b6f614 (Super+Z had been presented as free; option A's Super+Ctrl+Up from a side half gave a quarter). Options and their
meaning: `docs/audits/tiling-2026-10-27/decisions.md`.

| Question (short) | Owner's answer |
|---|---|
| T1a/T1f: the layout grid, where? | « Section du popover (Recommandé) » |
| T1b: the layout bar at the top of the screen during a drag? | « Non (Recommandé) » |
| T1c: suggestions to fill a layout, when? | « Hors glisser (Recommandé) » |
| T1d: groups of windows placed together? | « Oui, à la macOS (Recommandé) » |
| T1e: the shared edge? | « Toujours actif (Recommandé) » |
| T2: keyboard shortcuts, which option? | « A : macOS + Windows (Recommandé) » |
| T2a: the key that opens the popover (Super+Z was an error: Super+Z = ⌘Z, Undo)? | « Super+Ctrl+L (Recommandé) » |
| T2b: Super+Ctrl+Up/Down from a side half (a quarter in option A, the half on macOS)? | « Moitiés macOS + U I J K (Recommandé) » |
| T3: the neutral names? | « Noms proposés (Recommandé) » |
| T4: Full Screen tile? | « Étape 6 dédiée (Recommandé) » |
| T5: the green light click? | « Garder ADR-0002 (Recommandé) » |
| T6: the order of the steps? | « Cet ordre (Recommandé) » |

## Evidence
- Hyprland facts above: read in the v0.56.2 sources (commit efb50993, matching the owner's installed 0.56.2), file and line
  references in `docs/audits/tiling-2026-10-27/sources.md`. Not compiled or run in this session (no Hyprland, no DRM device
  in the cloud container).
- macOS: Apple Help pages for macOS 15, 26 and 27 ("Tile windows", "Mac window tiling icons & keyboard shortcuts", "Change
  window tiling settings", "Desktop & Dock"), the WWDC24 AppKit session, the macOS 27 release notes, public captures of the
  512 Pixels library; the earlier owner-capture measurements of the popover (230 × 251, radius 12, 26-pt glyphs on a 52
  pitch; `docs/testing/f1-reference-gaps.md` item 20). Windows 11: Microsoft Support and Windows Insider pages. Sources per
  row in the parity matrix.
- Existing behaviour: `compositor/src/core/Tiling.hpp`, `compositor/src/Tiling.cpp`, `compositor/src/Titlebar.cpp`,
  `shell/menubar/model/AppMenuModel.qml`, `config/hypr/grassfield/bindings.lua` and `forwarding.lua` on main 68ee009.

## Consequences
- ADR-0002 gains an amendment line pointing here; `docs/specs/compositor.md` drops "tiled windows" from its non-goals; the
  behaviour lives in `docs/specs/tiling.md` (FR47-FR50 stay in compositor.md as the plugin's existing requirements).
- New plugin code depends on more Hyprland internals, to re-verify on every Hyprland update (the ABI check stops a
  mismatched build): `CDragStateController::{mode, target}` and the order `input.mouse.move` → `moveMouse`;
  `CLayoutManager::{endDragTarget, beginDragTarget}` to restart a drag; `CWindow::m_events.resize`;
  `CWindow::{minSize, maxSize, parent}` (a rule replacing the client's minimum) and the xdg commit clamp;
  `CMonitor::logicalBoxMinusReserved`; the translation of floating windows on output removal.
- gfc/1 grows additively (verbs, a notice event, a reply); the contract table of ADR-0007 is updated in the same commit as
  the code of each step, `tests/ci/gfc_parity.py` enforces it. Every new shell IPC function is listed in
  `docs/specs/security.md` in the step that adds it (`ipc_inventory.sh`), and every new surface or entry point joins the
  lock refusals of security.md "Nothing opens over the lock" and `tests/security/lock_surfaces.sh` in that step.
- FR49's rule "a window moved or resized since its tiling is no longer tiled" gives way to the tile record's state machine
  (tiling.md TL10) in step 1; compositor.md FR49 is updated then.
- Gate C3: the plugin with the new internals builds and passes C1/C2 against the Hyprland of the Omarchy rc channel before
  it reaches stable (the CI job of master-prompt §11); the internals list below is re-read on each Hyprland update.
- The layout catalogue becomes a token group; `gen-tokens.py` gains its C++ and QML output.
- What we give up: Hyprland's tiled layouts in the Grassfield session stay out of tiling (SUPER+T still floats or tiles a
  window the Hyprland way, outside Grassfield's tiles); xdg TILED_* states are not managed per window; no per-move
  animation curve.
- Revisit if Hyprland adds a supported floating algorithm selection, a drag begin/end event, or per-window xdg states.
