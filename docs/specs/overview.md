# Overview spec (Mission Control equivalent) · shell-engineer + compositor-engineer · M2 (v1), M3 (v2)

## macOS reference behavior (described in words)
- Ctrl+Up or a 3/4-finger swipe up zooms out: all windows of the current Space spread without overlap,
  scaled, keeping relative positions, with app name labels under hovered windows; the desktop dims slightly.
- A Spaces bar at the top shows thumbnails of each Space (labelled "Desktop 1", …) and a "+" to add a Space;
  dragging a window onto a Space moves it.
- Click a window to focus it and zoom back in; Esc or Ctrl+Up again exits. Animations ~300 ms, spring-like.

## Purpose and non-goals
v1 (M2): shell surface with ScreencopyView thumbnails of toplevels (Quickshell `ScreencopyView` with
Hyprland toplevel capture), layout algorithm, Spaces bar, keyboard nav, drag to Space.
v2 (M3): live transforms of real windows by `grassfield-compositor` (`grassfield:overview on`) when the
capability is present. Non-goal: capturing protected surfaces.

## Functional requirements
1. O1 Toggle via IPC `overview toggle` (CTRL+UP) and gesture (owner config, L2).
2. O2 Layout: non-overlapping grid preserving relative positions, max scale 0.8, min gap 24 px; unit-tested.
3. O3 Thumbnails live-update (Full profile) or snapshot once (Reduced profile).
4. O4 Spaces bar: one tile per workspace on the monitor + "+" creates the next workspace.
5. O5 Drag a window thumbnail onto a Space tile → `movetoworkspacesilent`.
6. O6 Keyboard: arrows move selection, Return focuses, Esc exits.
7. O7 Minimized windows appear in a separate strip (M2 with minimize).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| O2 | layout unit tests (QML TestCase) | L0 |
| O1/O4/O6 | nested scenario with 6 windows + screenshots | L1 |
| P3 | frame timing open/close | L2† |
| S4 spike | ScreencopyView cost of 9 toplevels recorded in ADR-0006 notes | L1 |

## Known limitations
- v1 shows thumbnails, not the real windows moving; real-window transforms need the plugin (v2).

## v1 implementation (shell/overview/, 2026-10-17)
- `Overview.qml` (controller + IPC `overview toggle|open|close|status`), `OverviewWindow.qml` (one layer-shell
  overlay per output, namespace `grassfield-overview`, starts below the menu bar, keyboard exclusive while open),
  `Layout.js` (pure layout, keyboard neighbor search, input signature; `tests/unit/tst_overviewlayout.qml`).
- Layout: one uniform scale <= 0.8, centers scaled about the group's center, overlaps relaxed apart (min gap 24 px);
  if that does not fit, or row packing gives clearly larger windows (identical stacked windows), rows in reading
  order are used. Window rectangles interpolate from the real rectangle to the layout rectangle (zoom). Reduce
  Motion: no movement, crossfade capped at `motion.reducedMax`.
- Cost bounds: the area comes from the screen geometry (never the unconfigured layer-surface size) and the layout
  is recomputed only when the signature of window ids, rects and area changes. Row packing is a direct
  computation (rows 1..ceil(sqrt n)+1), the relaxed layout a <= 5-step binary search on the scale with <= 12
  relaxation passes. Offscreen: 20 windows ~12 ms, 9 ~6 ms (tests allow 20 ms); in the nested shell one layout
  takes 2-3 ms and open -> fully zoomed is the animation itself (~360 ms). Esc, like every other action, releases
  the keyboard before closing (a Space just created with "+" is kept). The action always closes the overlay (try/finally).
- Platform (`shell/platform/Compositor.qml`, new functions only): `spacesOn`, `windowsOn`, `nextSpaceId`,
  `focusSpace`, `moveToSpace` (address validated by `Minimized.moveRequest`, the single validator, Lua `hl.dsp.window.move({... follow = false ...})`),
  `refreshSpaces`, `topologyRevision`/`refreshOnEvents`.
- Spaces bar tiles (v1): "Desktop N", window count and up to 4 app icons; no capture of the workspace (the real
  tile thumbnails need v2). Click a tile: switch and close. "+": focus the next workspace id, Overview stays open.
- Click a window: activate and close. The keyboard grab is released 80 ms before the focus action, otherwise Hyprland
  refocuses the previous window (and workspace) when the exclusive layer goes away and undoes the switch.
- Keyboard: arrows (spatial), Return, Tab/Shift+Tab cycle windows -> each Space tile -> "+", Esc. Up from the top
  row of windows enters the Spaces bar.
- Profiles (`material.profile`): full = live `ScreencopyView`; balanced = single frames every
  `overview.balancedIntervalMs` (250 ms; the API has no rate control, so `captureFrame()` on a timer); reduced = one
  snapshot per window when opening.
- v2 branch point: `Overview.thumbnailMode` (`!Capabilities.has("overview")`, always true in v1).
- Backdrop: the wallpaper is a separate layer surface, so the overlay dims and blurs everything below it (real
  windows included, blurred) instead of showing a wallpaper-only backdrop; with Reduce Transparency the dim is
  near-opaque. A wallpaper-only backdrop needs the wallpaper art shared with the overlay (follow-up).

## S4 results (spike: ScreencopyView cost of 9 toplevels)
Nested Hyprland 0.56.2 on the owner's session (parent GPU path, UHD 630; indication only), 9 foot windows (700x500)
on one workspace, output GF-REF 1920x1080, idle terminals, 60 s windows, CPU = % of one core from /proc stat deltas.

| State | grassfield-shell CPU | grassfield-shell RSS | nested Hyprland CPU |
|---|---|---|---|
| Overview closed | 0.1 % | 292 MB | 0.0 % (RSS 167 MB) |
| open, full (live) | 104.8 % | 311 MB | 43.1 % |
| open, balanced (4 fps) | 1.3 % | 307 MB | 0.3 % |
| open, reduced (snapshot) | 0.1 % | 324 MB | 0.1 % |

- Live capture of 9 windows saturates the shell's main thread in this environment (every frame is copied, even
  for idle windows): full is not viable as a default here; the default profile (`balanced`) costs ~1 %.
- Observation (nested only, real session not verified): on the first open after the shell starts, the zoom
  animation progressed only to ~14 % and resumed after an external wake-up (IPC call); later opens reach 100 %
  within ~0.3 s. Needs a check on the real session (P3, L2).
