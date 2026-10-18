# Stages spec (stage manager equivalent) · compositor-engineer (plugin) + shell-engineer (strip) · M5

UI naming (renamed 2026-10-18, owner decision): "Space" in older notes is shown to the user as "Desktop" (fr « Bureau »).

Status: spike positive; plugin prototype behind a feature flag (plugin 0.6.0-stages, 2026-10-18, nested only); shell strip
NOT implemented (contract below). Decision: `docs/decisions/ADR-0013-stages.md` (Proposed). UI name **Stages** (§14);
the Apple name is never used in the UI. Code: `compositor/src/core/Stages.*` (model, validation, geometry, events; unit
tests `compositor/tests/StagesTest.cpp`), `compositor/src/Stages.*` (Hyprland glue), `compositor/src/WindowTransform.*`
(drawing shared with the overview), verb in `compositor/src/Ipc.cpp`. Nested scenario: `tests/compositor/stages.sh`
(`check`, `perf`) with the strip stand-in `tests/compositor/stages-fixture`.

## macOS reference behavior (ASSUMPTION: described from memory; no reference material was checked)
- When turned on, the windows of the current app (its "stage") are centred and usable; every other recent app (or group)
  is a small live thumbnail in a strip on the left edge, one tile per stage; the several windows of one app are stacked in
  its tile, and the app icon is shown with it.
- Clicking a tile swaps that stage with the current one, animated: the current windows shrink into the strip while the
  chosen ones grow back to where they were on the stage.
- Dragging a thumbnail onto the stage adds that window to the current stage; dragging a window from the stage to the strip
  makes it a stage of its own. Stages can be grouped (Shift-click a tile adds its windows to the current stage).
- Opening a window of another app starts a new stage (the previous one goes to the strip); activating an app another way
  (Dock, app switcher) brings its stage forward.
- The strip hides when a window overlaps it and reappears when the pointer reaches that edge.
- Each display and each Desktop has its own stages. Full-screen apps are Desktops of their own.
- Off by default; turned on in Quick Settings (and Settings).

## Purpose and non-goals
Purpose (M5, master-prompt §5.6 item 6, §12): "Stage Manager (plugin layout + shell strip), behind a feature flag",
the highest-risk feature, last. This spike decides where the model lives and how Hyprland 0.56.2 can hide windows while
showing them live in a strip, and delivers a plugin prototype with a precise shell contract.

Non-goals of the prototype: the shell strip UI (shell-engineer, from the contract below), persistence of stages across a
plugin or shell restart, the "one window at a time" app mode, showing desktop icons while Stages is on (a shell choice),
tiled windows (ADR-0002: floating-first; tiled and pinned windows stay out of Stages), transforming popups, a perspective
tilt of stacked thumbnails (they are stacked flat, 8 px apart).

## Functional requirements
- **ST1** Feature flag: `hl.plugin.grassfield.config("stagesEnabled", "true"|"false")`, validated like
  `titlebarDoubleClick` (exact strings; anything else is rejected and logged, no change). Off at every plugin load.
  Turning it off ends Stages at once (every window shown normally).
- **ST2** Capabilities: `stages-available` whenever the Stages listeners, `hl.plugin.grassfield.stages` and `config`
  registered (the shell shows the Quick Settings toggle); `stages` only while the flag is on (always together with
  `stages-available`). A change of the flag re-posts the capabilities.
- **ST3** `op:on` (flag on, strip surface present, ST17) groups the managed windows of every workspace by app (window
  class): one stage per app; the stage of the focused window (else of the front window) is active; the others form the
  strip, most recent first (by their front-most window in the stacking order). Managed windows: mapped, visible,
  floating, not pinned, on a regular workspace, not X11 override-redirect; at most 64 per workspace (others are shown
  normally).
- **ST4** The active stage's windows are shown and usable at their real places, unchanged.
- **ST5** Every window of a strip stage stays mapped on its workspace at its real place and is drawn, live, into its tile
  (`Render::IWindowTransformer`, as the overview): its surface box fitted with its 28 px titlebar band (uniform scale,
  never enlarged, centred) into its stack position; stacked windows of one stage step 8 px up-left (at most 3 distinct
  positions, the front window bottom-right). Stages beyond the tiles are drawn off the monitor (not visible). No client is
  ever moved, resized or configured.
- **ST6** Strip windows take no input at their real places: the plugin sets its own input block reason
  (`CWindow::setInputBlocked`, bit `1 << 6`), so Hyprland's hit test skips them for pointer focus, clicks, hovers and
  titlebar presses. Keyboard: a strip window focused by any other path brings its stage forward (ST10).
- **ST7** `op:activate` swaps a strip stage with the active one: the outgoing windows animate from their real places to
  their tiles, the incoming ones from their tiles to their real places, other strip stages move between tiles, over the
  `durationMs` and `curve` of the latest `op:on`, interpolated every frame by the plugin; the incoming front window is
  focused. Input of the incoming windows is unblocked before the focus, the outgoing ones blocked after it.
- **ST8** A new window (or one restored or moved in from another workspace) joins the stage holding a window of the same
  app, which becomes active; otherwise it opens a new active stage and the previous active stage leads the strip.
- **ST9** A window that closes, unmaps, moves away, becomes pinned or tiled leaves its stage at once (shown normally); an
  emptied stage disappears; when the active stage empties, the most recent strip stage becomes active. When the closed
  window held the keyboard, the active stage's front window takes it unless Hyprland gave it to a window of that stage.
- **ST10** Hyprland focusing a strip window with a user reason (key binding, dispatch, Dock, activation request) brings
  its stage forward; a strip window Hyprland picks after a close (reasons `UNMAP_*`) does not: the active stage keeps the
  keyboard.
- **ST11** `op:move` moves a window into a stage of its workspace (on top) or into a new strip stage (`"stage":"new"`;
  refused when the window is already alone); `op:merge` moves every window of a strip stage into the active stage.
  Requests naming an unknown stage or window change nothing (`reason:"unknown"`).
- **ST12** `hidden:true` in a strip slides its thumbnails out to the left of the monitor (animated); `hidden:false` brings
  them back.
- **ST13** The event reports `overlap:true` while a window of the active stage (or any input-accepting window of that
  workspace) intersects the strip band (tiles + 8 px): the shell then hides the strip.
- **ST14** Full screen: while the workspace shows a full-screen window its strip thumbnails are off the monitor; a strip
  window made full screen (dispatch by address) brings its stage forward.
- **ST15** Minimize: a minimized window (on `special:minimized`) leaves its stage; restored, it joins (ST8).
- **ST16** Overview: a window the overview transforms is drawn untransformed by Stages (the overview's transformer takes
  it from its real place); strip windows stay input-blocked under the overview's chrome.
- **ST17** Strip surfaces: a strip is accepted for a monitor only when a mapped layer surface with namespace
  `grassfield-stages` is on that monitor, on the Top or Overlay layer, and its box and its input region (corners and
  centre of each tile) cover every tile; otherwise `op:on` is refused (`reason:"no-strip"`). Thumbnails are thus drawn
  only where the shell takes the clicks: a click on a thumbnail can never reach a window hidden under the drawing.
  A workspace whose monitor has no strip is shown normally (its model is kept).
- **ST18** Failsafes: the strip surface going away (shell exit or unmap) shows that monitor's windows normally at once
  (`reason:"interrupted"`); a monitor removal or layout change drops the strips (`interrupted`); a later `op:on` resumes.
- **ST19** Unload: every window back to normal rendering with its input unblocked, transformers detached before
  `dlclose`, pending callbacks and the watchdog removed, `{"on":false,"reason":"unavailable"}` posted; a reload starts
  with the flag off.
- **ST20** Robustness (R11): the payload is copied out of Lua with non-raising calls and parsed strictly; events go
  through the event throttle (channel `stages`, one key, latest wins); request-triggered log lines share the request log
  budget; activate / merge / move requests change the model at once but are applied once per event loop pass, so a Lua
  dispatch with any number of requests causes at most one focus change (Hyprland's own `activewindow` events are not
  throttled: see "Spike results").
- **ST22** Workspaces: stages are per workspace; a workspace that is not shown on any monitor keeps its windows as they
  are drawn (blocked and in their tiles), so switching back (and Hyprland's workspace slide) finds them in place.
- **ST21** Degradation: without the plugin (or with an ABI mismatch, or with `stages-available` missing) Stages does not
  exist: no verb, no capability, Quick Settings hides the toggle; nothing in the shell depends on it.

## Acceptance criteria
| ID | Test | Level | Result (2026-10-18, nested Hyprland 0.56.2) |
|---|---|---|---|
| ST1-ST2 | unit `StagesFlag.ConfigAllowlist`, `Protocol.StagesFeaturesFollowAvailabilityAndTheFlag`; nested `stages.sh` checks 1-4 | L0 / L1 | PASS |
| ST3-ST5 | unit `StagesModel.*`, `StagesGeometry.*`; nested: grouping, sizes unchanged, thumbnails in tiles (terminal grey 88 % / 83 % of tiles 0 / 1, 0 % of empty tile 2), live (ticker tile 188 px changed in 0.6 s, idle tile 0 px) | L0 / L1 | PASS |
| ST6 | nested: click at b3's real place (covered by b3 only) → b3 gets nothing; keys go to the active stage | L1 | PASS |
| ST7 | nested: tile press reaches the strip surface; activate → b active, c to tile 0; frame mid-swap differs from before (58890 px) and after (80955 px); afterwards b3 takes clicks and keys; sizes unchanged | L1 | PASS |
| ST8-ST11 | unit `StagesModel.*`; nested: move, merge, new stage, unknown stage, new window, close (keyboard back to b3), focus by dispatch | L0 / L1 | PASS |
| ST12-ST13 | nested: hidden 0 % grey in tiles, shown 89 %; titlebar drag of b3 over the strip → `overlap` true, dragged back → false | L1 | PASS |
| ST14-ST15 | nested: full screen on and off (strip back); minimize → `special:minimized`, gone from stages; restore → in the active stage | L1 | PASS |
| ST16 | code path (`overviewer::transforms`); no nested check | L0 | NOT VERIFIED in nested |
| ST17-ST18 | unit `StagesGeometry.TilesMustLieInsideTheStripSurfaceAndTheMonitor`; nested: `no-strip` without the surface; strip process exit → `interrupted`, 0 % grey, every window takes input; `op:on` again resumes with its stages | L0 / L1 | PASS |
| ST19 | nested: `scripts/nestctl plugin unload` during Stages → rc 0, Hyprland alive, `unavailable`, no thumbnail, b3 takes clicks, sizes unchanged; reload → `stages-available` without `stages` | L1 | PASS |
| ST20 | unit `StagesRequest.*`; nested: 6 invalid payloads → `invalid`; 1000 activate requests in one dispatch → 1 stages event, 1 `activewindowv2`, no socket2 subscriber dropped | L0 / L1 | PASS |
| ST21 | `nested-up.sh --no-plugin` (no `grassfield` capabilities at all); shell side NOT implemented | L1 | plugin side by construction |
| ST22 | nested: switch to workspace 9 (no stage) and back: the same stage ids, thumbnails in the tiles | L1 | PASS |
| Multi-output | per-workspace model and per-monitor strips; only GF-REF had a strip in the run (WAYLAND-1 had no Stages windows) | L1 | NOT VERIFIED |

Run: `.dev/stages/run-20261018-141943-check` (**40/40 PASS**, plugin 0.6.0-stages, final build); perf
`.dev/stages/run-20261018-125334-perf`.

## Shell ↔ plugin contract (gfc/1, additive; for the shell-engineer — the shell side is not implemented)
1. **Detection.** `Capabilities.has("stages-available")` → show the Stages toggle in Quick Settings (off by default,
   persisted by the shell, e.g. `stages.enabled`). Without it (no plugin, mismatch, hooks failed, after the unload event
   with an empty list) hide the toggle and the strip. Push the setting after every capabilities event and on change:
   `hl.plugin.grassfield.config("stagesEnabled", "true"|"false")` (add the key to the config allowlist in
   `shell/platform/Minimized.js`). `Capabilities.has("stages")` → the flag is on: map the strip and send `op:on`.
2. **Strip surfaces** (one per output; only outputs with a strip are managed):
   - input surface: namespace **`grassfield-stages`**, `WlrLayer.Top` (or Overlay), anchored to the left edge, keyboard
     `None`, **transparent where the thumbnails are** (the plugin draws them in the window layer, under Top). Its input
     region must cover every tile while the strip is shown (the plugin checks the corners and centre of each tile); when
     the strip is hidden, shrink the input region to a thin edge zone for the hover reveal and send `hidden:true`.
   - optional plates (tile backgrounds, hover highlight): a separate surface on `WlrLayer.Bottom` (below windows, like the
     overview backdrop). App icons and labels may go on the Top surface outside the thumbnail rects.
3. **Turn on / update** (after the strip maps): `hl.plugin.grassfield.stages("<json>")` through `Hyprland.dispatch`,
   guarded like the other verbs (add `stages` to `isPluginVerb`), built only from validated pieces and quoted as a Lua
   string:
   `{"op":"on","durationMs":350,"curve":[0.2,0,0,1],"strips":[{"monitor":"GF-REF","hidden":false,"tiles":[{"x":…,"y":…,"w":…,"h":…},…]}]}`
   - Tiles in layout coordinates (global logical, like `hyprctl clients`), slot 0 first (top). Limits (else
     `reason:"invalid"`): object ≤ 8 KiB; `op` required; `durationMs` integer 0..2000 (required for on; 0 = Reduce
     Motion); `curve` 4 numbers, x in [0,1], y in [-1,2]; at most 8 strips with distinct monitor names
     (`[A-Za-z0-9._-]`, ≤ 64 bytes); 1..8 tiles per strip, sides 16..800 px, finite, not overlapping. Known keys that do
     not belong to the op are refused; unknown keys are skipped.
   - `op:on` again while on updates the strips, timing and `hidden` flags (no regrouping). Send it on every geometry
     change of the strip (output added or moved, Dock or menu bar size) and for the hover reveal (`hidden:false`).
   - `{"op":"off","durationMs":350}` ends Stages (animated back). Turning the flag off also ends it (at once).
4. **Events** `grassfield>>{"v":"gfc/1","type":"stages","on":bool,"monitors":[{"monitor":"GF-REF","workspace":2,"active":5,"hidden":false,"overlap":false,"stages":[{"id":5,"slot":-1,"windows":[{"address":"<hex, no 0x>"}]},{"id":7,"slot":0,"windows":[{"address":"…","x":…,"y":…,"w":…,"h":…}]}]}]}`
   plus `"reason":"invalid|disabled|no-strip|unknown|unavailable|interrupted"`. Coalesced (latest wins): treat as a
   state. Per monitor with a strip: the workspace shown there, the active stage id, the stages in recency order (active
   first, `slot` = tile index, −1 for the active stage and for stages beyond the tiles), each stage's windows back to
   front, and for windows in a tile the rect where their **surface box** is drawn (their 28 px titlebar band is drawn
   above it, scaled), always at the shown position (also while `hidden`). `disabled`: flag off; `no-strip`: the strip
   surface is missing, not Top/Overlay, or does not cover the tiles with its box and input region; `unknown`: the stage
   or window no longer exists (refresh from the next event); `interrupted`: the strip surface went away or the monitors
   changed: re-send `op:on`; `unavailable`: the plugin unloads (hide the strip).
5. **Clicks and drags** (the shell maps them through its own tiles and the event's rects; windows never get the strip's
   input):
   - click on tile k → `{"op":"activate","stage":<id of the stage with slot k>}`; Shift-click →
     `{"op":"merge","stage":<id>}`;
   - drag a thumbnail (hit-test the tile's windows front to back, i.e. the list reversed) and drop it on the stage area →
     `{"op":"move","address":"0x<hex>","stage":<active id>}`; drop on another tile → that tile's stage id;
   - drag a window of the stage to the strip (the shell sees it through Hyprland's move events; or a titlebar context
     action) → `{"op":"move","address":"0x<hex>","stage":"new"}`;
   - activating an app from the Dock or Search needs nothing special: Hyprland's focus of a strip window brings its stage
     forward (ST10).
6. **Strip visibility.** Hide the strip (slide out, `hidden:true`, input region to the edge zone) while `overlap` is true;
   reveal it on hover at the left edge (`hidden:false`) and hide it again when the pointer leaves. Prototype limit: a strip
   revealed over an overlapping window draws its thumbnails under that window (Hyprland's stacking order is kept), so
   keep the strip hidden while `overlap` is true unless the user is at the edge.
7. **Restart.** After each capabilities event with `stages`, re-send the flag and `op:on`; the plugin keeps its model
   while it stays loaded (a strip that went away showed the windows normally until then).
8. **Overview.** Include strip windows in the overview layout like any window (they are eligible); clicking one there
   focuses it, which brings its stage forward (ST10).

## Spike results (2026-10-18, nested Hyprland 0.56.2 commit efb50993, GF-REF 1920x1080 scale 1; parent GPU path, indication only)
Sources of Hyprland v0.56.2 read as data (`desktop/state/ViewHitTester.cpp`, `FocusState.cpp`, `view/Window.cpp`,
`render/Renderer.cpp`, `render/ElementRenderer.cpp`, `managers/input/InputManager.cpp`, `desktop/state/WindowState.cpp`,
`output/Monitor.cpp`); every API used was checked in `/usr/include/hyprland` and the exported symbols
(`nm -D /usr/bin/Hyprland`: `CWindow::setInputBlocked`, `CWindow::acceptsInput`, `CEventLoopManager::doLater`).

**Model location: the plugin** (see ADR-0013). Window membership must change synchronously with Hyprland (a window must
not flash in the centre before the shell reassigns it; a closed window's stage must update before Hyprland picks its
successor), the input block is a safety property that must not depend on the shell staying alive, and unload must be able
to undo everything at once. The shell owns the presentation: tile geometry, chrome, hover, drag and drop, the setting.

**Mechanism candidates for the windows of inactive stages:**

| Candidate | Live thumbnail | Input at real place | Client untouched | Verdict |
|---|---|---|---|---|
| Same workspace + `IWindowTransformer` + plugin input block reason | yes (rendered every frame with damage; frame callbacks keep flowing) | blocked: `CViewHitTester::windowAt` skips windows whose `acceptsInput()` is false | yes (never moved, resized or configured) | **chosen** |
| Special workspace (`special:…`) + snapshots | no: Hyprland sends frame callbacks only to views of a monitor's active (special) workspace (`sendFrameEventsToWorkspace`), so parked clients stop presenting; a live thumbnail would need the plugin to render surface trees itself | none (not on a visible workspace) | moved to another workspace (movewindow events, workspace rules, the shell's Dock sees it) | rejected (frozen, more code), but cheapest |
| `CWindow::setHidden` | no: hidden windows are not rendered, so the transformer is never called | none | yes | rejected |
| Real geometry moved off every monitor | no: `shouldRenderWindow` needs the window on a monitor | none | position changes (XWayland clients see it) | rejected |
| Raising strip windows above the active stage (`CWindowState::raise`) | – | – | – | not used: it also sets `m_allowedOverFullscreen` (drawn over full-screen windows) |

**CPU** (`tests/compositor/stages.sh perf 30`: 9 foot windows, 3 apps × 3; % of one core from `/proc/<pid>/stat`, 30 s
per phase; ticker = one terminal printing 10 lines/s; run `.dev/stages/run-20261018-125334-perf`, on the build before the request coalescing and the hidden-workspace fix, which do not change the per-frame work):

| Phase | nested Hyprland | grassfield-shell | Hyprland RSS |
|---|---|---|---|
| Stages off, idle | 0.2 % | 1.0 % | 162 MB |
| Stages off, ticker shown | 3.2 % | 0.1 % | 162 MB |
| Stages on (2 strip stages = 6 windows drawn live in tiles), idle | 0.1 % | 0.2 % | 162 MB |
| Stages on, ticker in a strip tile (live thumbnail) | 4.4 % | 0.1 % | 162 MB |
| Stages on, ticker in the active stage | 4.3 % | 0.1 % | 162 MB |
| Stages on, a swap every second (350 ms animations) | 12.0 % | 2.1 % | 162 MB |
| special workspace alternative: 6 windows parked, idle | 0.1 % | 0.1 % | 162 MB |
| special workspace alternative: ticker parked (not rendered: frozen) | 0.0 % | 0.1 % | 162 MB |

An idle strip costs nothing (no damage, no frame). Live thumbnails cost ~1.2 points of one core per 10 fps content
change in this environment (every frame with damage redraws the 6 transformed windows through Hyprland's work buffers),
the price of liveness the special-workspace alternative avoids by freezing. Swaps cost what the overview's animation
costs (12.2 % for continuous open/close there).

**Swap animation.** One clock for all windows (start, `durationMs`, curve); each window interpolates from where it is
drawn now (its tile, or its live box) to its target (its new tile, or its live box), like the overview's retarget; windows
shown normally again lose their transformer at the end; a 150 ms watchdog completes an animation when no monitor renders.

**Findings during the prototype runs** (nested, fixed before the final run):
1. A flood of 1000 `activate` requests in one Lua dispatch, applied one by one, made ~1000 real focus changes: Hyprland
   posted 967 `activewindowv2` events within one second and dropped the shell's socket2 connection
   (`Socket2 fd 57 overflowed event queue, removing`); the shell then missed `minimize-request` (`minimize.sh` FAIL).
   Requests are now applied once per event loop pass (ST20): 1 event, 1 `activewindowv2`, no subscriber dropped.
2. A reload after an unload kept the flag on: the library can stay mapped between loads (FR23 pinning), so its
   function-static state survives; `start()` and `stop()` now reset the flag and the model.
3. (self-review, before the final run) A workspace switched away was retargeted as "no strip, shown normally": its strip
   windows would have animated back to their real places during the workspace slide and flown back on return. A
   workspace shown on no monitor now keeps its windows as they are drawn (ST22).

**Interactions** (ST13-ST16): minimize, full screen, overlap and desktop focus checked in nested as above; the overview
code path makes strip windows draw from their real places in an open overview (they jump from their tile to the centre
when the overview opens: prototype limit); desktop focus is unaffected (a press on a thumbnail is a press on a
`grassfield-*` layer; strip windows are never press targets because the hit test skips them).

## Known limitations and risks
- Popups of strip windows are not transformed: a menu open when its window goes to the strip stays drawn at its real place
  (usually closed first by the click outside it). Not exercised.
- A strip revealed over an overlapping window draws its thumbnails under it (contract item 6).
- The input block uses an unused bit of Hyprland's `eWindowInputBlockReason` (`1 << 6`): internal API, re-verify on every
  Hyprland update (the ABI hash check prevents running against another build).
- Separate Lua dispatches, each activating a stage, cause one focus change each, like Hyprland's own `hl.dsp.focus`.
- No persistence: stages are rebuilt from the windows when Stages turns on; a shell restart shows the windows normally
  until it sends `op:on` again; a plugin reload starts with the flag off.
- Multiple outputs, fractional scales and rotated outputs are not verified; the strip of a monitor whose workspace shows
  a full-screen window is hidden.
- The shell strip, Quick Settings toggle and Settings entry are not implemented (shell-engineer); F1 visual fidelity not
  assessed (no strip UI).
