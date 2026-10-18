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
v2 (M3): live transforms of real windows by `grassfield-compositor` (`hl.plugin.grassfield.overview(json)`, feature
`overview`) when the capability is present (compositor side done 2026-10-18, see "v2 implementation"; shell side
pending). Non-goal: capturing protected surfaces.

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
| v2 spike | live transforms: mechanism, layering, input, CPU, cleanup (`tests/compositor/overview.sh check`, `perf`) | L1 |

## Known limitations
- Contrast (A2, open finding): the Spaces bar captions use `textSecondary` on the black dim over the wallpaper, not on
  Material, so the exact token calculation (`tests/visual/test_contrast_tokens.py`) lists them as an exempt role
  ("overview captions") and `contrast.sh` has no Overview surface. Their ratio is not measured; fix by measuring the
  Overview surface with the glyph mask, or by moving the captions to the primary text colour.
- v1 shows thumbnails, not the real windows moving; real-window transforms need the plugin (v2).
- v2 (plugin side): popups are not transformed, full-screen windows are not transformed, fractional scales and
  rotated outputs are not verified (see "Shell contract" item 8).

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
- Blur timing: the compositor re-blurs the full-screen region every frame while the surface animates (nested
  swap up to 1 s). `BackgroundEffect.blurRegion` is set only once the zoom-in has finished and dropped when the
  zoom-out starts; the dim animates on its own. The overlay window is persistent (one per screen, always mapped,
  empty input mask and hidden content between opens). Nested, 3 open/close cycles: max swap 717-1110 ms ->
  107 ms.
- Close (Esc, backdrop click) releases the keyboard grab, then re-focuses the Space that was active on that
  output when closing started, so Hyprland's refocus of its last window cannot jump back after "+".

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

## v2 spike (live transforms in grassfield-compositor, 2026-10-18)
Nested Hyprland 0.56.2 (commit `efb50993780079460b0cbed1363e2166a2de1d9f`) on the owner's session (parent GPU path,
UHD 630; indication only), output GF-REF 1920x1080 scale 1, plugin 0.4.0-ov2 built against `/usr/include/hyprland`.
Hyprland's v0.56.2 sources were read as data (`render/Renderer.cpp` `renderWindow`, `render/ElementRenderer.cpp`
`drawTransformedWindow` and `drawSurface`, `render/pass/Pass.cpp`, `render/OpenGL.cpp`, `output/MonitorResources.cpp`)
and every API used was checked in the installed headers. Runs: `.dev/overview/run-20261018-001222` and
`run-20261018-003207` (check, both PASS; the figures below are from the first), `run-20261018-001341` (perf).

**Mechanism: a `Render::IWindowTransformer` per transformed window** (`CWindow::m_transformers`, public; Hyprland uses
it for its own motion blur and only ever touches its `CMotionBlurTransformer` entries, through `dynamic_cast`).
- With a transformer attached, `renderWindow` records the window's main pass (decorations, surface, subsurfaces) into
  a sub-pass and adds a `CTransformedWindowPassElement`. At draw time Hyprland renders that sub-pass into a cleared
  monitor-sized work buffer, passes it to each transformer's `transform(fb)` and composites the returned buffer over
  the whole output, limited to the frame damage (the element disables pass simplification, so every element gets the
  whole frame damage instead of its own bounding box).
- The plugin's `transform()` draws the received buffer into a second pooled work buffer, scaled and moved so that the
  window's surface box lands on its layout rect (the minimize snapshot math, `core textureBox`), and returns it. The
  decorations (titlebar, border, shadow) scale with the window.
- The client is never resized nor configured: `hyprctl clients` at/size identical before, during and after (check
  "sizes"). Its buffers are sampled every frame: a terminal printing the time every 200 ms changes inside its layout
  rect between two frames while an idle one does not (check "live": 2233 px vs 0 px). Frame callbacks keep flowing
  because the surfaces are drawn in the sub-pass.
- Damage: animation ticks (`render.preChecks`, like Hyprland's own animations) damage each window's previous and new
  visual box, which schedules the next frames. While open, `render.pre` (after Hyprland's animation tick, before
  `beginRender` reads the damage ring) adds the layout boxes of that output to its damage ring whenever the output has
  damage (`m_damage.hasChanged()`), because Hyprland damages a window's real place when its content changes. An idle
  open overview renders no frame at all.

Rejected:
- **Renderer hints** (`CRendererHintsPassElement` with a translate + scale `SRenderModifData` around a window's elements,
  from `RENDER_PRE_WINDOW` / `RENDER_POST_WINDOW`): `renderModif` moves the drawn boxes but not the damage: surfaces are
  drawn with `damage ∩ windowBox` in unmodified coordinates (`drawSurface`) and scissored with unmodified rects
  (`renderTextureInternal`), and pass simplification uses unmodified bounding boxes and opaque regions. A window moved
  outside its real box is clipped away, and its opaque region still hides what is under its real place.
- **`CWindow` animated variables** (`m_realPosition` / `m_realSize`): they configure the client (`sendWindowSize`), as
  already found for minimize.
- **Function hooks or calling the protected `renderWindow`**: fragile against Hyprland updates and not needed.
- **Capturing a window's elements with `redirectPass` and replaying them after the Overlay layer** (windows above the
  shell's dim): needs a nested pass render on the main framebuffer, damage save/restore and a second software cursor
  draw, popups bypass the redirect, and windows would cover notifications. The layering has a simpler answer (b).
- **`makeSnapshotFB` per window per frame**: a newly allocated monitor-sized framebuffer and a full window render per
  frame; the transformer path renders into Hyprland's pooled work buffers.

Defects found and fixed during the spike (nested only, before any further run):
1. `CMonitor::resources()` is a weak pointer over a unique pointer: `lock()` hits a hyprutils assertion (abort, not an
   exception, so `gf::guarded` cannot catch it) and the nested Hyprland crashed with SIGABRT on the first transformed
   frame. The plugin now checks and dereferences it, as Hyprland's `drawTransformedWindow` does.
2. After rendering the window into the work buffer Hyprland leaves `m_renderData.damage` at the window's box: a clear
   inside `transform()` then cleared only that box, and the previous content of the reused work buffer was composited
   over the output as noise. `transform()` now sets the damage to the whole buffer for its clear and draw and restores
   it afterwards.

Answers:
- **(a) Windows.** The shell lists them; the plugin transforms a window only if it is mapped, not hidden, not pinned,
  on the active, non-special workspace of its monitor (minimized windows on `special:minimized` are excluded) and not
  full screen (`FSMODE_FULLSCREEN`; maximized windows are transformed), and if its rect lies inside that monitor. A
  window that closes, moves to another workspace, becomes full screen or pinned while the overview is shown goes back
  to normal rendering at once. Popups are not transformed (Hyprland: "transformers for now only affect the main pass").
- **(b) Layering.** The windows stay in Hyprland's normal window pass, between the Bottom and the Top layers. Chosen:
  the shell splits its overview in two surfaces: the backdrop (dim, and blur through `BackgroundEffect` if wanted) on
  the **Bottom** layer, above the wallpaper and the desktop icons (Background) and below the windows, and the chrome
  (Spaces bar, labels, selection, input) on the **Overlay** layer with a transparent background. No holes, no second
  animation to keep in step, notifications, OSD and the cursor keep their place, and the Dock (Top) stays above the
  windows as on macOS. Verified with the stand-in `tests/compositor/overview-fixture` (screenshot `open.png` of the
  check run: dimmed wallpaper, crisp windows, labels and Spaces bar on top). Rejected: windows above the Overlay layer
  (see `redirectPass` above); the shell layer on Top with a transparent area (its dim still covers the windows unless
  it punches holes); holes (the shell would have to animate them in step with the plugin's per-frame boxes: one or two
  frames of offset at ~3 px/ms leave a 50-100 px band of dim on moving windows).
- **(c) Input.** With the windows transformed, the fixture's Overlay chrome (whole-surface input, keyboard exclusive)
  received a click at the capture window's real, untransformed place (outside every layout rect), a click on its image
  and a key; the window itself (a foot reporting mouse buttons and typed bytes) received nothing and the active window
  did not change (check "input"). Hyprland's input routing is untouched: real windows keep their real boxes.
- **(d) CPU** (`tests/compositor/overview.sh perf 30`: 9 foot windows 700x500 on GF-REF, 30 s per phase where S4 used
  60 s, % of one core from `/proc/<pid>/stat`):

| Phase | nested Hyprland | grassfield-shell | fixture (v2 chrome stand-in) | Hyprland RSS |
|---|---|---|---|---|
| closed, idle | 0.2 % | 0.5 % | – | 161 MB |
| closed, one terminal printing 10 lines/s | 3.7 % | 0.2 % | – | 161 MB |
| open, idle | 0.3 % | 0.3 % | 0.0 % | 161 MB |
| open, one terminal printing 10 lines/s | 6.4 % | 0.1 % | 0.0 % | 161 MB |
| open/close every 0.5 s (350 ms animations, continuous) | 12.2 % | 0.4 % | 0.0 % | 161 MB |

  v1 live thumbnails of the same 9 windows: shell 104.8 %, nested Hyprland 43.1 % (S4). The grassfield-shell column is
  the running shell with its v1 overview closed: a v2 shell captures nothing and its chrome is static.
- **(e) Animation.** The shell sends `durationMs` (0 = Reduce Motion) and optionally the timing curve (cubic-bezier
  control points, default `Tokens.motionCurveStandard` 0.2, 0, 0, 1); the plugin interpolates every frame, so there is
  no per-frame IPC. A new layout while open continues from where each window is drawn. Hyprland's animation variables
  are not used: they belong to its config animation tree, and per-frame interpolation is already proven by minimize.
- **(f) Exit and cleanup.** `on:false` animates back, then detaches the transformers: the output after matches the
  output before (0.35 px differ, menu bar masked). A plugin unload during an open overview detaches every transformer
  in `PLUGIN_EXIT` (normal rendering on the next frame, windows at their place, Hyprland alive) and posts
  `closed`/`unavailable`; loading the plugin again brings the feature back. Failsafes: the chrome surface (namespace
  `grassfield-overview`) going away, or a window getting the keyboard, closes the overview; a workspace switch or a
  monitor change puts every window back at once. Refused requests change nothing and report the reason, so the shell
  falls back to thumbnails; without the plugin (or with an ABI mismatch) there is no `overview` feature at all.

Result: positive; implemented as below.

## v2 implementation (compositor side, 2026-10-18)
Code: `compositor/src/core/Overview.*` (payload parser and validation, interpolation, event JSON; unit tests
`compositor/tests/OverviewTest.cpp`), `compositor/src/Overview.*` (transformers, damage, failsafes), verb in
`compositor/src/Ipc.cpp`. Plugin requirements: `docs/specs/compositor.md` FR25-FR29. Nested scenario:
`tests/compositor/overview.sh` (`check`, `perf`) with the stand-in `tests/compositor/overview-fixture/shell.qml`.

### Shell contract (for the shell-engineer; the shell side is not implemented yet)
1. **Capability.** `Capabilities.has("overview")` selects v2 (`Overview.thumbnailMode` false); otherwise v1.
2. **Surfaces** (per output):
   - backdrop, namespace `grassfield-overview-backdrop`, `WlrLayer.Bottom`, full screen, no input (empty mask), dim
     from tokens (near-opaque with Reduce Transparency), blur through `BackgroundEffect` if wanted (it only blurs the
     wallpaper and the desktop: the windows are above it). Same-layer surfaces stack in mapping order: map it when the
     overview opens so that it is above the desktop widgets (Bottom), or decide that they stay undimmed.
   - chrome, namespace **`grassfield-overview`**, `WlrLayer.Overlay`, transparent background (no dim or blur where
     windows are drawn), Spaces bar, labels, selection, whole-surface input, keyboard `Exclusive` while open (as v1).
     **Required by the plugin** (R13 fix 2026-10-18): an `on:true` that would transform windows is refused with reason
     `no-chrome` unless every monitor of those windows has a mapped chrome surface with `Exclusive` keyboard
     interactivity and the keyboard is on a chrome surface (or one of its popups). While windows are shown, the chrome
     unmapping ends the overview at once (`closed`/`interrupted`, no closing animation) and the keyboard leaving the
     chrome ends it (`interrupted`). After sending `on:false` the shell may unmap the chrome: the closing animation it
     asked for runs to its end.
3. **Open / update.** Once the chrome holds the keyboard, send `hl.plugin.grassfield.overview("<json>")` through
   `Hyprland.dispatch`, guarded like the other verbs (add `overview` to `isPluginVerb` in `shell/platform/Minimized.js`),
   the JSON built only from validated pieces (hex address, finite rounded numbers) and quoted as a Lua string (escape
   `\` and `"`). Payload:
   `{"on":true,"durationMs":350,"curve":[0.2,0,0,1],"windows":[{"address":"0x…","x":…,"y":…,"w":…,"h":…},…]}`.
   - Rects are layout coordinates (global logical, like `hyprctl clients` at/size) of where the window's **surface box**
     (at/size, without the titlebar) is drawn. The scale is uniform: a rect of another aspect ratio gets the window
     centred in it. The plugin's titlebar (28 px) and shadow are drawn around it, scaled: keep `28 × scale` free above
     each rect and include that band in hit-testing and label placement.
   - Limits (else the request is refused): a JSON object of at most 16 KiB; `on` (bool) and `durationMs` (integer
     0..2000) required; `windows` required when `on` is true, at most 64 entries, unique addresses, finite numbers,
     `w` and `h` ≥ 1; `curve` 4 numbers, x in [0, 1], y in [-1, 2]. Ignored per window (not refused): an unknown or
     ineligible window (see (a)), a rect not inside the window's monitor (1 px tolerance).
   - `on:true` again while open (a window opened or closed, a window dragged to a Space) retargets: listed windows
     animate from where they are drawn, windows left out go back to their place at once.
   - Use the same `durationMs` and curve for the shell's own label and chrome animation.
4. **Close.** `{"on":false,"durationMs":350}` (curve optional), before or together with the focus action. The plugin
   also closes on its own when a window chosen by the user takes the keyboard from the chrome (v1 releases the grab,
   then activates the clicked window), when the keyboard leaves the chrome, when the chrome goes away (at once), and at
   once on a workspace switch or a monitor change. A window closing or opening while open does **not** end the
   overview, also when it was the active window (Hyprland then moves focus; the chrome keeps the keyboard): the window
   leaves the layout, the plugin posts the state with the new count, and the shell retargets with a new `on:true`.
5. **Events** `grassfield>>{"v":"gfc/1","type":"overview","state":"opening|open|closing|closed","windows":N}`, plus
   `"reason":"invalid|no-windows|no-chrome|unavailable|interrupted|fullscreen"` when relevant. They are coalesced
   (latest wins, at most one per 100 ms): treat them as a state, not as a log. `invalid` / `no-windows` / `no-chrome`:
   the request was refused, the state is unchanged: show thumbnails for this open (`no-chrome`: the chrome was not
   mapped, not Exclusive or did not hold the keyboard yet). `unavailable`: the plugin is unloading: thumbnails from now
   on. `interrupted`: the overview ended without the shell's `on:false`: close the chrome. `fullscreen`: a window went
   full screen while shown; the windows of its workspace went back to normal rendering (state unchanged): retarget
   without them or close. `windows` smaller than the number sent: some windows were not eligible (full screen, on a
   workspace showing a full-screen window, pinned, another workspace): leave them out or show thumbnails for them.
6. **Input.** Clicks and keys go to the chrome; the shell maps them through its own rects. Hyprland's real window
   boxes are unchanged during the overview, so activation, drag to a Space and close act on the real window as in v1.
7. **Restart.** After each `capabilities` event, if the shell has no overview open, send `{"on":false,"durationMs":0}`
   (idempotent: a closed overview answers `closed`).
8. **Limits to show honestly:** popups (menus) of a window stay at its real place and are not scaled; full-screen
   windows, and the other windows of a workspace that shows a full-screen window, are not transformed (decision
   2026-10-18: on macOS a full-screen app is a Space of its own, shown as a Spaces bar tile, and Hyprland draws only the
   full-screen window on such a workspace); Spaces bar tiles of other workspaces still need captures (nothing of another
   workspace is rendered); fractional scales and rotated outputs are not verified.

### R13 fix pass (2026-10-18, plugin 0.5.0-df)
Review of f12f610 (FAIL): major `on:true` accepted without the chrome; minors: active-window close ended the overview,
full-screen windows ignored at workspace level, `render.pre` never updated the last damaged box, check count misstated.
Fixes: chrome requirement and failsafes (contract items 2 and 4), retarget on close (item 4), full-screen decision (items
5 and 8), damage (`core damageStep`: the box drawn in each frame becomes the last damaged box, so a surface resized while
open has every box it was drawn in damaged again, also the box detached at close). Measured: Hyprland 0.56.2 emits
`window.active` for the closing window itself (reason "other") while it refuses the keyboard to the next window because
the chrome is Exclusive: the failsafe now requires a mapped window that took the keyboard away from the chrome.
`tests/compositor/overview.sh check`: **29/29 checks PASS** (the run prints `PASS (n/N checks)`; the f12f610 version had
20 checks, not 21 as reported). Screen captures cannot show stale pixels (a capture with the damage fix reverted showed
none either; captures most likely repaint the whole output): the resize check reads the plugin's damage log instead, and
it fails on the reverted build (`open box height 351, box damaged at the start of the shrink none`) and passes on the fix
(`351 → 491`).
