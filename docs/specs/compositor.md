# grassfield-compositor spec · compositor-engineer · M0 spike S2 → M1 decorations → M2 minimize → S5 appmenu

Status: titlebars, gfc/1 capabilities, minimize/restore with animation (M2), the `config` verb
(double-click setting) and the appmenu protocol server (feature 3, step A of global menus; spike S5) implemented.
Code: `compositor/`. Build and run: `compositor/README.md`.

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)

- Every standard window has a titlebar strip about 28 pt tall that is part of the window: same corner
  radius as the window at the top, square joint with the content, one continuous outline and shadow.
- Three circular buttons on the left, 12 pt diameter, evenly spaced (8 pt gaps), vertically centered:
  close, minimize, zoom. Glyphs appear on hover; inactive windows show grey buttons.
- The window title is centered on the full titlebar width in semibold system text, never overlapping the
  buttons, truncated with an ellipsis when too long.
- Dragging the titlebar moves the window; double-clicking it performs the user's chosen action (default: zoom).
- Buttons act on mouse-up over the same button (press, move away, release = cancel).
- Minimize: the window shrinks into its own tile in the Dock, right of the separator ("Scale" effect: the
  window shrinks uniformly while it moves, accelerating; "Genie" bends it into the tile), in about a third of
  a second; clicking the tile plays it backwards and makes the window key again.

## Purpose and non-goals

Purpose (S2): prove that a Hyprland 0.56.2 plugin built against the installed headers can draw and drive
macOS-like titlebars on floating windows, and that the shell can discover the plugin's capabilities over
IPC under Hyprland's Lua config (input for ADR-0007). M2: real minimize with an animation toward the Dock
tile rectangle the shell sends (ADR-0002), and the user's double-click setting.

Non-goals: the "Genie" warp (the animation is the "Scale" effect: uniform shrink + move; a genie would need a
mesh-deformed texture draw, which Hyprland's pass elements do not offer), hover glyphs and inactive-state
buttons, appearance switching, tiled windows, CSD negotiation, overview transforms; for appmenu: reading or
rendering DBusMenu menus (that is `grassfield-menu-bridge` and the shell, step B, ADR-0008), the
`com.canonical.AppMenu.Registrar` service, X11 (XWayland) menus.

## Functional requirements (numbered, testable)

- **FR1** The plugin refuses to hook anything when `__hyprland_api_get_hash()` differs from
  `__hyprland_api_get_client_hash()`, logs the mismatch and shows one notification.
- **FR2** Every mapped floating window (not full screen, `decorate` rule not false, not X11
  override-redirect) gets a titlebar decoration 28 px (logical) tall above its content; tiled and
  full-screen windows get none (zero extents).
- **FR3** The titlebar background uses the window's corner radius and rounding power on its top corners,
  is square at the bottom, and fills the content's rounded top corners; the window border and shadow
  wrap titlebar + content.
- **FR4** Close, minimize, zoom buttons: 12 px circles, 8 px gaps, first one 12 px from the left edge,
  vertically centered; colors from `compositor/src/core/Theme.hpp` (close `#E5534B`, minimize `#D9A93B`,
  zoom `#4FA64F`; background dark `rgba(40,40,44,1)` / light `rgba(236,236,238,1)`, dark in S2).
- **FR5** The title is centered on the bar and kept at least 8 px clear of the buttons (symmetric margins);
  it is limited to the remaining width.
- **FR6** A left press on a button arms it; releasing over the same button activates it: close → close the
  window (Hyprland's close action); zoom → toggle full-screen mode *maximized*; minimize → post
  `minimize-request`; the shell, which owns the Dock tile rectangle, answers with
  `hl.plugin.grassfield.minimize(address, rect)` (FR14), or parks the window on `special:minimized` itself
  when the plugin lacks the `minimize` feature.
- **FR7** A left press elsewhere on the bar focuses and raises the window (without warping the cursor) and
  starts an interactive move that follows the pointer from the press point; release ends it. The move (and
  an armed button, FR6) also ends, where it is, on any new press, and on a pointer motion when Hyprland
  reports no held button or a pointer device present at the press has disappeared: a lost release never
  leaves the window following the pointer.
- **FR8** Two presses on the drag area within 400 ms and 4 px do what Settings say
  (`windows.titlebarDoubleClick`, pushed by the shell, FR16): `zoom` (default) → the zoom button's toggle
  (no move); `minimize` → the minimize button's path (FR6); `none` → nothing (the second press is a single
  press). A press moves the window only after the pointer travelled more than 4 px
  (`kDragThreshold`); a click never writes the window geometry. A drag that starts on a maximized window
  first leaves the maximized mode and places the restored floating size under the pointer (same horizontal
  fraction of the window, same offset on the titlebar), then follows the pointer (macOS).
- **FR9** At load and on `hl.plugin.grassfield.hello()` the plugin posts the socket2 event
  `grassfield>>{"v":"gfc/1","type":"capabilities","features":[...]}`: `decorations` always; `minimize` only
  when the `minimize`/`restore` Lua functions and the minimize render hooks registered; `config` only when the
  `config` Lua function registered (`["decorations","minimize","config"]` when everything works).
- **FR10** `hyprctl grassfield` returns the same capabilities JSON.
- **FR11** No exception escapes into Hyprland; window/monitor pointers are null-checked; no blocking I/O.
- **FR12** `PLUGIN_EXIT` removes all titlebars, Lua functions, the hyprctl command and event listeners,
  and ends a drag in progress. Titlebars of unmapped or hidden windows are destroyed too (Hyprland defers
  their removal), and no pointer to a destroyed titlebar stays in Hyprland's plugin bookkeeping.
- **FR13** Input consistency: the plugin never cancels a pointer button event, so Hyprland's held-button
  state always matches the device and the click after any titlebar gesture reaches the window under the
  pointer. Press ownership: a titlebar consumes a release if and only if a titlebar consumed the matching
  press (per button; a new press of a button supersedes an older one) and Hyprland routes that release to
  a titlebar; elsewhere the release reaches the seat, which drops it for a client that never got the press.
  The release of a press that went to a client is never consumed, even over a titlebar.
- **FR14** `hl.plugin.grassfield.minimize(address, x, y, w, h)`: `address` is a string `0x` + 1–16 hex
  digits of a mapped window, `x, y, w, h` (numbers, layout coordinates) the Dock tile. Everything is
  validated (string and number types read without raising Lua errors, address parsed, never dereferenced but
  compared with the live windows, rectangle finite, 1–1024 px per side and fully inside one monitor); the
  function always returns `hl.dsp.no_op()`. An invalid address is ignored; an invalid rectangle means "no
  animation". The window is snapshotted, moved to `special:minimized` at once (same hidden state as the
  shell's fallback), and its snapshot shrinks uniformly (aspect ratio kept, centered in the tile) and moves
  into the tile in 300 ms with an ease-in curve (cubic Bézier 0.4, 0, 1, 1), fading out over the last 20 %.
  Then `grassfield>>{"v":"gfc/1","type":"minimized","address":"<hex>"}` is posted (at once without
  animation). A window already on `special:minimized` is left alone.
- **FR15** `hl.plugin.grassfield.restore(address, x, y, w, h)`: same validation. A window on
  `special:minimized` moves back to the focused monitor's active workspace at its floating geometry (Hyprland
  keeps it on the special workspace), is focused and raised at once, and stays transparent while its snapshot
  grows from the tile to its box in 300 ms (ease-out, the time-reverse of FR14's curve, fading in over the
  first 20 %); then it is shown and `{"type":"restored"}` is posted. A restore during a minimize animation
  (or a minimize during a restore) completes the running one first; a minimize interrupting a restore starts
  from the restore's current box.
- **FR16** `hl.plugin.grassfield.config(key, value)`: allowlist `titlebarDoubleClick` = `zoom` | `minimize` |
  `none` (exact strings); anything else is rejected (logged, no change); returns `hl.dsp.no_op()`. The shell
  pushes the setting after each capabilities event and whenever Settings change.
- **FR17** Minimize robustness: a window closed during its animation drops the animation (no event); a
  monitor removed or the monitor layout changing completes every animation at once; unloading the plugin
  completes every animation (a restoring window is made visible, minimized windows stay on
  `special:minimized` for the shell's fallback), drops the snapshots and removes the render hooks and timer;
  nothing is drawn while the session is locked (the drawing hook is not emitted then).
- **FR18** Appmenu global: at load the plugin advertises `org_kde_kwin_appmenu_manager` version 2 (KDE's
  protocol, `compositor/protocols/appmenu.xml`; version 2 adds the manager's `release`), created with
  `wl_global_create` on Hyprland's display; feature `appmenu` is advertised only when the global and the Lua
  function `appmenu` both registered. Version 1 clients (Qt 6.11, Chromium 152) work unchanged.
- **FR19** `org_kde_kwin_appmenu.set_address(service_name, object_path)` is untrusted input: accepted only when
  the service is a D-Bus bus name (unique `:1.42` or well-known `org.foo.Bar`: at least 2 non-empty
  dot-separated elements of `[A-Za-z0-9_-]`, well-known elements not starting with a number, at most 255 bytes)
  and the path a D-Bus object path (`/` or `/`-separated non-empty `[A-Za-z0-9_]` elements, no trailing `/`, at
  most 255 bytes). Anything else is ignored (no protocol error, the client stays connected; one log line per
  object). Strings are JSON-escaped anyway.
- **FR20** The plugin keeps, per `wl_surface`, the latest valid address (the latest request on any appmenu
  object of that surface wins; releasing an object drops the registration it made) and maps the surface to
  its toplevel window when that window is mapped (comparing `CWindow::resource()`, nothing the client sent is
  dereferenced). It posts `grassfield>>{"v":"gfc/1","type":"appmenu","address":"<hex>","service":"…",
  "path":"…"}`: when a mapped window's registration changes (an unchanged one is not re-posted), when a window
  is mapped with one, and for every focused window (with empty service and path when it has none), coalesced
  per window (FR24). A registration made before the window is mapped is posted at map.
- **FR21** When an announced registration goes away — the window is unmapped (`window.close`) or destroyed,
  the appmenu object is released or destroyed (client exit), or the surface is destroyed — the plugin posts
  the same event with `"service":"","path":""`. A window mapped again on the same surface is announced again.
- **FR22** `hl.plugin.grassfield.appmenu(address)`: `address` as in FR14; for a mapped window the plugin posts
  its `appmenu` event (registration or empty); an invalid or unknown address posts nothing (logged). Returns
  `hl.dsp.no_op()`. The shell calls it after a restart (or a missed event) for the windows it shows.
- **FR23** Unload never leaves a Wayland object pointing into the unloaded library: at compositor shutdown
  (`g_pCompositor->m_isShuttingDown`) every appmenu resource and the global are destroyed in `PLUGIN_EXIT`;
  on a runtime unload with client objects alive the library pins itself (`dlopen(RTLD_NOLOAD | RTLD_NODELETE)`),
  removes the global (`wl_global_remove`) and keeps those objects inert (requests ignored, destructors honored),
  and the shell receives a clear event for each announced window; with no client object the global is simply
  destroyed. If pinning fails the objects are destroyed (their clients get a protocol error at their next
  request on them; logged as an error).
- **FR24** No request can flood socket2 (R11). Hyprland disconnects a socket2 subscriber whose event queue
  overflows (`Socket2 fd N overflowed event queue, removing`); Quickshell then gets no Hyprland event until it
  restarts. Every plugin → shell event goes through a throttle (`core/EventThrottle.*`, glue `gf::ipc::postEvent`)
  keyed by (kind, window): `appmenu` per window, `minimize-request` per window, `minimized`/`restored` per window
  (one key: two values of one state), `capabilities` (one key). An event replaces a waiting event of the same key
  (the latest wins); a key posts at once when it has not posted in the last 100 ms, otherwise its latest event is
  posted 100 ms after the previous post by a Hyprland event loop timer (`CEventLoopTimer`; trailing edge: the
  final state of a burst is never dropped). Hard caps: 10 posts per key per second (by construction: two posts of
  one key are ≥ 100 ms apart); all keys together 32 at once, then 50 per second (token bucket; waiting events keep
  their latest-submission order, so a key that keeps changing goes behind keys that changed once). Unload posts
  every waiting event, then removes the timer. Log lines that requests trigger (appmenu bind/create/set_address,
  rejected Lua verb arguments, `config`, titlebar presses and actions from any pointer) share one budget of 20 lines, then 1 per second, and the next written line
  reports how many were held back; set_address is logged at the 1st, 10th, 100th, ... request of an object, never
  per request.

## Acceptance criteria (each mapped to a test or scenario; level L0/L1/L2)

| FR | Test / scenario | Level | S2 result |
|---|---|---|---|
| FR1 | Code review of `PLUGIN_INIT`; scripted mismatch test (C2) | L0 / L1 | match path verified (log); mismatch path NOT VERIFIED |
| FR2 | nested: open foot → screenshot | L1 | verified (floating); tiled/full-screen hiding NOT VERIFIED |
| FR3 | nested screenshot, corner crops | L1 | verified at scale 1 (see limitations) |
| FR4 | unit `TitlebarLayout.*`, `Theme.*`; screenshot | L0 / L1 | verified |
| FR5 | unit `TitlebarLayout.Title*`; screenshot with long and short titles | L0 / L1 | verified |
| FR6 | nested: virtual pointer clicks on close / zoom / minimize; press on close + release elsewhere; `tests/compositor/minimize.sh` | L1 | verified (close closed the window; zoom toggled `fullscreen` 0↔1; cancel kept the window). Minimize (2026-10-17): the button posted `minimize-request`, the shell answered with `hl.plugin.grassfield.minimize`, the window went to `special:minimized` (see FR14) |
| FR7 | nested: virtual pointer drag, window position before/after; abandoned drag (pointer tool exits after `down drag`, its device is destroyed) then move and click elsewhere with a new pointer | L1 | verified: press (500,186) → release (600,286) moved the window (370,200) → (470,300), cursor not warped. Abandoned drag (2026-10-17): before the fix the window followed the unpressed pointer and jumped to the next click; after it the window stays where the drag left it, the next click lands on the desktop, log `titlebar gesture cancelled: no button held or a pointer device went away` |
| FR8 | unit `ClickTracker.*`, `DragThreshold.*`, `UnzoomedDragBox.*`; nested `tests/compositor/zoom_restore.sh`, `tests/compositor/double_click_setting.sh` | L0 / L1 | Setting (2026-10-17, `double_click_setting.sh` PASS): `minimize` → window on `special:minimized`, `none` → geometry and mode unchanged, `zoom` → maximize then restore 700×500 at (610,264). Zoom: verified: `fullscreen` 0 → 1, titlebar kept on the maximized window. Restore by double-click on the maximized bar (2026-10-17): before the fix `fullscreen` 1 → 0 but the window kept the maximized box (1920×980 at the work-area origin) because the first click started a titlebar move whose release wrote the maximized box into the floating geometry (a single click on the maximized bar followed by the zoom button did the same); after the fix (no geometry write below the drag threshold; a drag on a maximized window un-zooms it under the pointer) double-click restores 700×500 at (2050,264), the original place; click + zoom button restores it too; a drag on the maximized bar from 25 % of its width to (1000,400) on GF-REF un-zoomed the window to 700×500 with its surface at (2265,414): pointer at 25 % of the width, 14 px above the surface (on the titlebar); a normal drag moves by exactly (+100,+150). Scenario: `tests/compositor/zoom_restore.sh` |
| FR9 | spike `spikes/s2-ipc/shell.qml` (Quickshell `rawEvent`); unit `Protocol.OnlyRegisteredFeaturesAreAdvertised`; shell log | L0 / L1 | verified for `hello`; 2026-10-17 shell log `compositor plugin present, features: decorations,minimize,config`; load-time event not observable |
| FR10 | `hyprctl grassfield` against the nested instance | L1 | verified: `{"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config"]}` (2026-10-17) |
| FR11 | code review; `clang-tidy` (Q1); C1 soak `tests/compositor/soak.sh` | L0 / L1 | see "Performance (gates affected)" |
| FR12 | `just plugin-unload` (needs `scripts/nestctl`); nested shutdown (SIGTERM → `CCompositor::cleanup` → `unloadAllPlugins` → `PLUGIN_EXIT`, then dlclose, then windows destroyed) with windows on `special:hidden` | L1 | runtime `hyprctl plugin unload` NOT VERIFIED (no `scripts/nestctl`); shutdown with 2 windows on `special:hidden`: log `[grassfield] grassfield-compositor unloaded`, `Hyprland has reached the end.`, no core dump. Hidden (`isHidden()`) / unmapped-window path: code inspection only |
| FR13 | unit `PointerGesture.*`; nested `tests/compositor/input_consistency.sh` (two mouse-reporting foot windows: fast titlebar drag and close-button press moved away on C, then a click inside B) | L0 / L1 | 2026-10-17, 3 rounds (6 gestures): before the fix (releases cancelled on the bus) FAIL, exit 1: all 6 clicks inside B were delivered to C at its edge (`[<0;1;1M`/`m`), B got none; after the fix PASS, exit 0: B got all 6 clicks (`[<0;13;8M`/`m`), C got no button event, 2 seat warnings `sendButton release on a non-pressed button` (the dropped releases). Also after the fix: double-click maximize, zoom-button restore, drag (+140,+150 exact), close press moved away (window kept), close click (closed) |
| FR14 | unit `MinimizeAddress.*`, `MinimizeTarget.*`, `MinimizeGeometry.*`, `MinimizeEasing.*`, `MinimizeFrames.*`, `MinimizeSnapshot.*`; nested `tests/compositor/minimize.sh` | L0 / L1 | 2026-10-17, `minimize.sh 20` PASS exit 0 (run `.dev/minimize/run-20261017-065654`): titlebar button → `minimized` event, window on `special:minimized`, Dock tile appeared (the Trash moved exactly one slot right: 0 px differ; the new slot differs from the Trash by 421/2304 px); move → `minimized` event 368 ms (animated); a capture during the animation shows the window at ≈90 % size moving toward the target (`minimize-frames.png`). Earlier back-to-back captures (`.dev/shots/minimize-burst.png`) show the shrink across 3 frames. Without a valid rectangle (the shell's Dock target outside the current monitor layout after the nested WAYLAND-1 window was resized) the move → event time is ≈0 ms: minimized without animation, as specified |
| FR15 | same | L0 / L1 | same run: click on the Dock tile → `restored` event 395 ms after the move back (animated), window back at 700×500 (610,264) on workspace 2 and focused (`activewindow`); captures during the animation (`restore-frames.png`, `.dev/shots/restore-burst.png`) show it growing from the target. Rapid repetition: 20 minimize + restore rounds, every 4th restore clicked 120 ms after the minimize click: 0 missing events, final geometry unchanged; a second run of 60 rounds on a fresh instance: PASS (22 + 26 of them animated before the nested WAYLAND-1 window was resized, the rest without animation) |
| FR16 | unit `Protocol.ConfigAllowlist`, `tst_minimized` `configCall`; nested `double_click_setting.sh` | L0 / L1 | 2026-10-17 PASS (see FR8). Push after the handshake: before the fix the shell's first push was skipped (`features` is assigned before `pluginPresent`, so `has("config")` was still false); after it the shell logs `compositor setting titlebarDoubleClick = minimize` right before `plugin present` and a fresh plugin honored it |
| FR18 | `hyprctl grassfield`; plugin log; `WAYLAND_DEBUG` of clients (`tests/compositor/appmenu.sh`) | L1 | 2026-10-17 verified: features `["decorations","minimize","config","appmenu"]`; log `appmenu: org_kde_kwin_appmenu_manager version 2 advertised`; Qt and Chromium see `wl_registry.global(69, "org_kde_kwin_appmenu_manager", 2)` and bind version 1; the edge-case client binds version 2 and releases the manager without error |
| FR19 | unit `AppmenuBusName.*`, `AppmenuObjectPath.*`, `AppmenuAddress.*`, `Protocol.AppmenuJson*`; nested `appmenu.sh edge-cases` | L0 / L1 | 2026-10-17 verified: 15 invalid requests (empty, missing parts, space, `..`, leading number, `:1`, Latin-1 byte, relative path, `//`, trailing `/`, `-` in a path, JSON-breaking quotes, 299-byte name and path) ignored, client still connected (roundtrip without error), no event |
| FR20 | unit `AppmenuRegistry.*`; nested `appmenu.sh qt-registrar`, `chromium` | L0 / L1 | 2026-10-17 verified: Qt sent `set_address(":1.1", "/MenuBar/1")`, released it, then `set_address(":1.1", "/MenuBar/2")`, both before map; the plugin posted one event right after `openwindow` with `/MenuBar/2`; Chromium's second window (File > New window clicked through DBusMenu) got its own event (`/com/canonical/menu/3`); focus path verified in run `run-20261017-113205` (`activewindowv2` → appmenu event, empty strings for an unregistered window) |
| FR21 | unit `AppmenuRegistry.*`; nested `appmenu.sh` | L0 / L1 | 2026-10-17 verified: File > Quit through DBusMenu → `closewindow` then the clear event (same address, empty strings); killed apps (all variants) → clear event |
| FR22 | nested `appmenu.sh qt-registrar` (Quickshell `Hyprland.dispatch`, `tests/compositor/appmenu-reemit/`) | L1 | 2026-10-17 verified: three calls (the window, `"0xnot-hex"`, `"0x1"`) → exactly one event, for the window; log `appmenu: rejected: invalid window address`, `appmenu: no mapped window 1 (or appmenu inactive)` |
| FR23 | nested shutdown with live appmenu clients (`scripts/dev/nested-down.sh`); code review | L1 | 2026-10-17 shutdown verified: `appmenu: global and 5 client object(s) destroyed (shutdown)`, `Hyprland has reached the end.`, no core dump; runtime unload NOT VERIFIED (no `scripts/nestctl`) |
| FR24 | unit `TokenBucket.*`, `EventThrottle.*`, `LogLimiter.*`, `LogMilestone.*` (timer simulated, time injected); nested `tests/compositor/event_flood.sh` (`appmenu-client --spam N`: a mapped window, N valid set_address on one object in one burst, last path `/MenuBar/final`; one Lua dispatch with 1000 `hello()` + 1000 `appmenu(<window>)`; after each flood a foot window with its own app id must become the menu bar's window, `qs ipc call menubar bridgeState`) | L0 / L1 | 2026-10-17. Before the fix (plugin at 6791eea, run `.dev/event-flood/run-20261017-174942`, exit 1): 200 requests → 200 `appmenu` events; the Lua flood → 491 `capabilities` + 490 `appmenu` events (and 491 `config` pushes back from the shell), `Socket2 fd 52 overflowed event queue, removing` (the shell) and `fd 87` (the test's socat), the shell's menu bar stuck on an old window, 202 plugin log lines. After (run `.dev/event-flood/run-20261017-185707`, exit 0): 200 requests → 2 events (`/MenuBar/1`, then `/MenuBar/final`), 25000 requests (sent in 83 ms) → 3 events ending with `/MenuBar/final`; Lua flood → 2 `capabilities` + 2 `appmenu`; no overflow line, no shell event socket error, the shell showed each new foot window; 14 plugin log lines for 25200 requests + 2000 Lua calls |
| FR17 | nested `minimize.sh` step 4; code review; unload path | L1 | 2026-10-17: a window killed 100 ms into its minimize animation and another killed 100 ms into its restore animation: both gone, the other window unaffected, nested Hyprland alive, no core dump of its PID. Monitor removal and runtime plugin unload mid-animation: NOT VERIFIED (no hotplug in nested; no `scripts/nestctl` for `plugin unload`); shutdown with the plugin loaded: see FR12. Lock screen: code inspection only (RENDER_POST_WINDOWS is not emitted while locked, Hyprland 0.56.2 `renderAllClientsForWorkspace`) |

## Interfaces / contracts (versions)

`gfc/1` (master-prompt §5.3). Measured transport in S2:

| Direction | Mechanism | Payload |
|---|---|---|
| plugin → shell | Hyprland socket2 event `grassfield` | `{"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config"]}` (FR9) |
| plugin → shell | socket2 event `grassfield` (minimize button, double-click set to minimize) | `{"v":"gfc/1","type":"minimize-request","address":"<hex, no 0x>"}` |
| plugin → shell | socket2 event `grassfield` (end of a minimize / restore) | `{"v":"gfc/1","type":"minimized","address":"<hex>"}`, `{"v":"gfc/1","type":"restored","address":"<hex>"}` |
| shell → plugin | Lua function `hl.plugin.grassfield.hello()` via `Hyprland.dispatch("hl.plugin.grassfield.hello()")` | re-posts capabilities |
| shell → plugin | `hl.plugin.grassfield.minimize("0x<hex>", x, y, w, h)` / `restore(...)` (Dock tile, layout px, integers) | FR14 / FR15 |
| shell → plugin | `hl.plugin.grassfield.config("titlebarDoubleClick", "zoom"\|"minimize"\|"none")` | FR16 |
| plugin → shell | socket2 event `grassfield` (appmenu registration of a mapped window changed, window mapped with one, window focused, re-emit) | `{"v":"gfc/1","type":"appmenu","address":"<hex>","service":"<bus name>","path":"<object path>"}`; `"service":"","path":""` = no menu (FR20–FR22) |
| shell → plugin | `hl.plugin.grassfield.appmenu("0x<hex>")` | re-posts that window's appmenu event (FR22) |
| client → plugin | Wayland global `org_kde_kwin_appmenu_manager` v2 (`create(new_id, wl_surface)`, `release` since 2); `org_kde_kwin_appmenu.set_address(s, s)`, `release` | FR18–FR21 |
| query | `hyprctl grassfield` | capabilities JSON |

The shell sends every verb guarded (`local p = hl.plugin and hl.plugin.grassfield; if p and p.<verb> then
p.<verb>(...) end`), built only from validated pieces (`shell/platform/Minimized.js`: verb allowlist, hex
address, finite rounded numbers, config allowlist).

Findings for ADR-0007 (evidence in "Automated tests · Manual verification steps"):

1. Under Hyprland 0.56.2's Lua config, `hyprctl dispatch X` and Quickshell 0.3.1's `Hyprland.dispatch(X)`
   are evaluated as Lua `return hl.dispatch(X)`. A legacy plugin dispatcher name (`grassfield:hello`,
   registered with `HyprlandAPI::addDispatcherV2`) is a Lua syntax error and is unreachable, so the plugin
   no longer registers it.
2. `HyprlandAPI::addLuaFunction(handle, "grassfield", "hello", fn)` exposes `hl.plugin.grassfield.hello()`.
   The function returns `hl.dsp.no_op()` so that `hl.dispatch(hl.plugin.grassfield.hello())` succeeds
   without an error reply.
3. Plugin → shell events posted with `g_pEventManager->postEvent({"grassfield", json})` arrive in
   Quickshell's `Hyprland.rawEvent` with `name == "grassfield"` and `data == json`.

Verbs follow the same pattern: `hl.plugin.grassfield.<verb>(args)`, results as `grassfield` socket2 events.
ADR-0007 lists `restore(address)`; the implemented verb takes the Dock tile too (`restore(address, x, y, w, h)`)
for the reverse animation; `config(key, value)` is new. Both are additions within `gfc/1` (no payload of an
existing message changed); the ADR's verb list should be updated by its owner.

## Appmenu (feature 3, spike S5): mechanism

Feasibility in Hyprland 0.56.2 (headers in `/usr/include/hyprland`, exported symbols of `/usr/bin/Hyprland`):

- `HyprlandAPI` (`src/plugins/PluginAPI.hpp`) has **no protocol or Wayland-global function**. What Hyprland's own
  protocols use is reachable from a plugin, though: `g_pCompositor->m_wlDisplay` (public member), libwayland-server
  (`wl_global_create`, `wl_global_remove`, `wl_global_destroy`, resolved from Hyprland's process), the exported
  `IWaylandProtocol` constructor / destructor / `removeGlobal`, the exported `CWLSurfaceResource::fromResource`,
  and hyprwayland-scanner 0.4.6, which generates the same kind of server wrappers Hyprland compiles
  (`COrgKdeKwinAppmenuManager`, `COrgKdeKwinAppmenu`). So a plugin **can** add a Wayland global. It is internal API
  covered by the same ABI-hash check as the rest of the plugin, not a stable plugin API: re-verify on every
  Hyprland update.
- `IWaylandProtocol` is not used: its bind trampoline is Hyprland's but calls a virtual of the plugin's subclass,
  and its destructor destroys the global at once. Plain libwayland keeps every pointer on the plugin side and lets
  the plugin choose between removing and destroying the global at unload.
- The generated code is compiled as its own object with `-fvisibility=hidden`: its `wl_interface` symbols cannot
  clash with a future Hyprland that would export the same names.
- **Unload hazard.** Every `wl_resource` the plugin creates points into the library (its `wl_interface` tables, the
  request table, the destroy listener); libwayland follows those pointers on each request and when the client
  disconnects, and Hyprland's shutdown order is `unloadAllPlugins` (PLUGIN_EXIT, `dlclose`) first, clients later.
  Destroying a resource the client still holds is no alternative at runtime: libwayland answers the client's next
  request on it with `invalid object` and disconnects the client. Hence FR23: destroy everything at shutdown,
  pin the library (`RTLD_NODELETE`) and keep the objects inert on a runtime unload with live client objects.
  The bind callback of a removed (not destroyed) global stays valid because the library stays mapped. Pinning
  is the technique GStreamer uses for plugins whose registrations cannot be revoked.
- Windows: `window.open` (map: announce a stored registration), `window.close` (unmap: clear),
  `window.destroy` (sweep registered windows that are no longer mapped), `window.active` (focus: post the focused
  window's registration or an empty one). The registrations themselves are pure logic (`core/Appmenu.*`).
- Third-party notice: `compositor/protocols/appmenu.xml` is KDE's protocol description (LGPL-2.1-or-later,
  © 2017 David Edmundson, notice kept in the file); the generated server code is compiled into the MIT plugin,
  as Hyprland (BSD-3-Clause) does with KDE's LGPL-2.1-or-later server-decoration protocol. To list in
  `THIRD_PARTY.md` and to cover in the §14 legal review (ADR-0005). Not a legal conclusion.

## S5 results

2026-10-17, nested Hyprland 0.56.2 with plugin 0.3.0-s5, Qt 6.11.2 (`qt6-base` 6.11.2-3: the Wayland QPA now lives
in qt6-base), Chromium 152.0.7977.82 (`/usr/lib/chromium/chromium` directly, so the owner's `chromium-flags.conf`
is not read; no extra flag), Firefox not installed (not tested; per §2 its Wayland global menu needs
`widget.gtk.global-menu.wayland.enabled`, off by default). Command: `tests/compositor/appmenu.sh <variants>`; each
variant runs on its own private D-Bus bus **without service activation** (no portal or other service can start),
the registrar is `tests/fixtures/fake-registrar`, the Qt app `tests/fixtures/menu-demo`. Runs
`.dev/appmenu/run-20261017-110915` (qt-registrar, PASS, exit 0), `run-20261017-110937` (five Qt variants, exit 0),
`run-20261017-111508` (chromium), `run-20261017-111403` (chromium-no-registrar), `run-20261017-111816`
(edge-cases, PASS), `run-20261017-112009` (qt-no-global).

| Variant | Registrar on the bus | Environment | Client requests (`WAYLAND_DEBUG`) | Menu bar in the window | Plugin event |
|---|---|---|---|---|---|
| qt-registrar | before the app | `QT_QPA_PLATFORMTHEME` unset | bind v1; `create`, `set_address(":1.1", "/MenuBar/1")`, `release`, `create`, `set_address(":1.1", "/MenuBar/2")`, all before map | hidden (DBusMenu bar) | yes, right after `openwindow`; clear after `closewindow` |
| qt-gtk3 | before | `QT_QPA_PLATFORMTHEME=gtk3` | same | hidden | yes |
| qt-portal | before | `QT_QPA_PLATFORMTHEME=xdgdesktopportal` (no portal on the bus) | same | hidden | yes |
| qt-kde | before | `XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6 KDE_FULL_SESSION=true` | same | hidden | yes |
| qt-no-registrar | none | unset | bind v1 only | shown | none |
| qt-late-registrar | 3 s after the app | unset | bind v1 only | shown | none |
| qt-no-global | before | `QT_WAYLAND_DISABLED_INTERFACES=org_kde_kwin_appmenu_manager` | none | **hidden** (no menu anywhere) | none |
| chromium | before | none | bind v1; `create`, `set_address(":1.2", "/com/canonical/menu/1")`; a second window: `/com/canonical/menu/3` | (browser has no menu bar) | yes, per window; clears at exit |
| chromium-no-registrar | none | none | bind v1 only | – | none |

(Menu bar visibility as reported by the app: `QMenuBar::platformMenuBar()` / `isVisible()`; visual NOT verified.)

DBusMenu side (same runs): Qt exports `com.canonical.dbusmenu` at the announced address (introspection lists the
interface; `GetLayout(0, -1, [])` returns File / Edit / View with submenus, mnemonics as `_`, shortcuts, toggle
state); `Event(id, "clicked", <0>, 0)` on File > New and on View > Theme > Dark (after `AboutToShow` on Theme) ran
the app's own actions (action log `file.new`, `view.theme.dark=on`), File > Quit closed the app and the plugin
posted the clear event. Chromium's object has **no introspection data** (empty node) and rejects untyped
arguments (`GetLayout` with `[]` guessed as `av` → `error occurred in GetLayout`); with explicit signatures
(`int32 0`, `int32 -1`, `@as []`) it returns File (New tab, New window, …), Edit, View, History, …, and
`Event(int32 2, "clicked", <int32 0>, uint32 0)` on "New window" opened a second browser window.

Findings:

1. **Qt 6.11 calls `set_address` if and only if `com.canonical.AppMenu.Registrar` is owned on the session bus
   when the menu bar is created** (QtGui creates its `QDBusMenuBar` only then; the check is done once, a registrar
   that appears later changes nothing). The platform theme (generic, gtk3, xdgdesktopportal, KDE) and KDE
   variables do not matter. Qt never calls `RegisterWindow` on Wayland: the registrar only has to exist; the link
   goes through `QWaylandPlatformServices::registerDBusMenuForWindow` → `org_kde_kwin_appmenu`. Service = the app's
   unique bus name, path `/MenuBar/<n>`; Qt recreates the object once while starting (before map).
2. **Chromium 152 behaves the same without any flag**: registrar present → one appmenu object per browser
   window at `/com/canonical/menu/<n>`; no registrar → nothing. Its DBusMenu needs explicit D-Bus signatures.
3. Both clients bind manager version 1; version 2 (manager `release`) is exercised only by the test client.
4. **Registrar without a working appmenu path hides menus**: with the registrar present but no global (or no
   compositor support), Qt hides its in-window menu bar and nothing shows the menu (qt-no-global). Owning the
   registrar is therefore only allowed while the whole chain works (plugin feature `appmenu`, bridge, shell
   menu bar), and never on the owner's bus during development.
5. KDE apps with the KF6 platform theme (plasma-integration) and GTK apps were not tested (not installed / no
   Wayland menu export).

Shutdown with live appmenu clients (FR23, `.dev/s5/shutdown-test.sh`, scratch): two menu-demo instances with
registered menus on a private bus, then `scripts/dev/nested-down.sh` (SIGTERM): the nested log ends with
`appmenu: global and 5 client object(s) destroyed (shutdown)`, `grassfield-compositor unloaded`,
`[PluginSystem] Plugin grassfield-compositor unloaded.`, `Hyprland has reached the end.`; no Hyprland core dump
since the start (`coredumpctl list --since`), no fixture process left. Runtime unload (pinning path): NOT
VERIFIED (no `scripts/nestctl`; `hyprctl plugin unload` is an owner action).

Full matrix on the same instance after the soak (run `.dev/appmenu/run-20261017-113205`, all ten variants,
RESULT PASS, exit 0): same results as the table; the windows took focus this time, so the focus path is
verified too: `openwindow` → appmenu (map) → `activewindowv2` → appmenu (focus, same registration); a window
without a registration gets `activewindowv2` → appmenu with empty strings; no clear is posted for a window that
never had a registration.

Regressions (same plugin build, 2026-10-17): `compositor/build-direct.sh tidy` exit 0, no diagnostic;
`grassfield-compositor-tests` 90/90 PASS (direct and CMake builds); `tests/compositor/input_consistency.sh 3`
PASS exit 0; `tests/compositor/soak.sh 300` PASS exit 0 (178 rounds, 22/22 minimizes animated, RSS 152.0 →
158.8 MB, no core dump, 0 grassfield exceptions); `tests/unit/tst_minimized.qml` 20/20 PASS. The CMake build
(`cmake -S compositor -B .dev/cmake-build -G Ninja`, now that cmake and ninja are installed) builds the plugin
and the tests (exit 0).

## Minimize (M2): mechanism

Chosen in Hyprland 0.56.2 after reading its headers and the v0.56.2 sources of `IHyprRenderer::makeSnapshotFB`,
`renderFadeouts`, `CWindowFadeout`, `CWindow::moveToWorkspace` and `CGlobalWindowController::moveWindowToWorkspace`
(upstream data, cross-checked with the installed headers and exported symbols):

- **Hidden state: `special:minimized`**, the special workspace the shell's fallback already uses
  (`Config::Actions::moveToWorkspace(ws, silent = true, window)`; the workspace is resolved like the Lua
  dispatcher does: `getWorkspaceIDNameFromString`, `State::workspaceState()->query().id()`, `create()` on the
  focused monitor). Consequences: the shell rebuilds its Dock tiles from it after a restart; a plugin unload,
  crash or mismatch leaves windows minimized and restorable by the fallback; a window minimized by the
  fallback is restored by the plugin and the other way round. Hyprland keeps the floating geometry of a window
  on a special workspace, so restore puts it back where it was (translated if restored on another monitor).
- **State first, animation second.** Minimize moves the window at once and animates a snapshot; restore moves
  it back at once (focused, transparent through `WINDOW_ALPHA_MOVE_FROM_WORKSPACE`, the alpha Hyprland itself
  animates 0 → 1 when a window arrives on a visible workspace) and shows it when the snapshot has grown back.
  Nothing can act on a half-minimized window, and an interrupted animation never leaves a wrong state.
  Hyprland's own fade-out of a window leaving a visible workspace (`WINDOW_ALPHA_MOVE_TO_WORKSPACE`) and its
  fade-in on arrival are completed at once (`warp()`), as the snapshot replaces them.
- **Animation: a transformed snapshot drawn by a render pass element.** `makeSnapshotFB(window)` (what
  Hyprland uses for its close animation: a monitor-sized framebuffer with the window, its titlebar, border
  and shadow at their place) is drawn with a `CTexPassElement` at the box `core/Minimize.cpp textureBox()`
  computes (Hyprland's `CWindowFadeout::renderBox` math, generalized to another monitor), clipped to the
  window's mapped box, from the `render.stage` event `RENDER_POST_WINDOWS` (after windows, under the top
  layers: the shrinking window passes under the menu bar and into the Dock). Each animation is ticked from
  `render.preChecks` (where Hyprland ticks its own animations), which damages the old and new boxes and so
  schedules the next frames; a 450 ms event-loop timer completes animations if no monitor renders.
- **Rejected: animating the window's own `m_realPosition`/`m_realSize` (`PHLANIMVAR`).** Their begin callback
  calls `sendWindowSize` (v0.56.2 `CWindow` map code), so the client would be configured to every
  intermediate size, the titlebar (fixed 28 px) would not scale, and the layout would fight the animation.
- **Rejected: a custom `Desktop::IFadeout` added to `fadingOutState()`.** It would render in Hyprland's own
  planes, but Hyprland would then hold objects whose vtable lives in the plugin: unloading safely needs
  `clear()` (drops Hyprland's own fadeouts) or relying on `cleanupForMonitor`; the plugin-owned pass element
  keeps every pointer on the plugin side.
- **Genie warp: out of scope** (a deformed mesh draw is not available through pass elements).

Crash safety: arguments are copied out of Lua with non-raising calls before any C++ work (Lua errors
longjmp); every hook runs in `gf::guarded`; windows are looked up by comparing addresses, held as weak
references, re-checked every tick (closed or unmapped → animation dropped); snapshots are released with
Hyprland's EGL context made current, never while a frame is being built; monitor removal or layout change
completes all animations; `PLUGIN_EXIT` (`minimizer::stop()`) removes listeners, completes animations
(restoring windows visible again), drops snapshots and removes the timer before the Lua functions go.

Pointer input contract with Hyprland (FR13), decided 2026-10-17 after the counter-review finding. The
plugin observes `input.mouse.button` and never cancels it, for presses and releases alike:

- Hyprland 0.56.2 appends a press to `m_currentlyHeldButtons` before dispatching it, so a press the titlebar
  consumes (`onInputOnDeco` returns true) is recorded as held exactly like a client press, and only a
  release that Hyprland processes removes it. While the list is not empty, `mouseMoveUnified` pins pointer
  focus (binary facts under "Dependencies").
- Keeping the press from the client needs nothing more: the titlebar is a decoration outside the client
  surface, so the consumed press never reaches `CSeatManager::sendPointerButton`.
- Keeping the release from the client needs nothing more either: over a titlebar the titlebar consumes it
  (only if a titlebar consumed the press, `CPointerGestureTracker::takeTitlebarRelease`); elsewhere the seat
  sends it only to a pointer resource that got the press (`CWLPointerResource::m_pressedButtons`), so a
  client that gained pointer focus during the drag gets nothing.
- Rejected: cancelling the release only (the previous strategy). Hyprland had recorded the press, so the
  button stayed held and pointer focus stayed pinned to the dragged window: the next click on another window
  went to it. Rejected: cancelling both press and release. Hyprland would then skip its whole button path
  (keybinds such as SUPER+drag on the bar, decoration routing, focus hold during the drag, refocus after the
  release), and the plugin would have to re-implement it; nothing is gained because the default path
  already keeps both events from clients.

## Dependencies (verified versions)

- Hyprland 0.56.2 (commit `efb50993780079460b0cbed1363e2166a2de1d9f`), headers in `/usr/include/hyprland`.
- APIs used (all read from the 0.56.2 headers): `HyprlandAPI::{addWindowDecoration, removeWindowDecoration,
  addLuaFunction, removeLuaFunction, registerHyprCtlCommand, unregisterHyprCtlCommand, addNotification,
  getHyprlandVersion}`, `Event::bus()->m_events.{window.open, window.floating, window.fullscreen,
  window.title, window.updateRules, input.mouse.button}` (observed, never cancelled; the deprecated
  `registerCallbackDynamic` is not used), `g_pEventManager->postEvent`, `IHyprWindowDecoration`,
  `g_pDecorationPositioner`, `g_pHyprRenderer->addPassElement` with `CRectPassElement` /
  `CTexPassElement`, `renderText`, `g_layoutManager->setTargetGeom` (move),
  `Desktop::focusState()->fullWindowFocus`, `Fullscreen::controller()->setFullscreenMode`,
  `Config::Actions::{closeWindow, alterZOrder}`, `Event::bus()->m_events.input.mouse.move`,
  `g_pInputManager->{hasHeldButtons(), m_pointers, getMouseCoordsInternal()}`,
  `CWindow::{m_windowDecorations, m_decosToRemove}`, `g_pDecorationPositioner->{uncacheDecoration,
  forceRecalcFor}`, `g_pPluginSystem->getPluginByHandle()->m_registeredDecorations`.
  Minimize (M2, also checked in the exported symbol table): `Event::bus()->m_events.{render.preChecks,
  render.stage (RENDER_POST_WINDOWS), window.close, monitor.removed, monitor.layoutChanged}`,
  `IHyprRenderer::{makeSnapshotFB(PHLWINDOW), damageBox, damageWindow, type(), m_renderData.pMonitor}`,
  `IFramebuffer::getTexture`, `Render::GL::g_pHyprOpenGL->makeEGLCurrent()`,
  `Config::Actions::moveToWorkspace(ws, silent, window)`, `getWorkspaceIDNameFromString`,
  `State::workspaceState()->{query().id().run(), create()}`, `State::monitorState()->monitors()`,
  `Desktop::focusState()->monitor()`, `CWindow::{alpha(WINDOW_ALPHA_MOVE_TO_WORKSPACE |
  WINDOW_ALPHA_MOVE_FROM_WORKSPACE), getWindowMainSurfaceBox, getWindowExtentsUnified, geometricBox(GOAL),
  positionAnimation, sizeAnimation}`, `CEventLoopTimer` with `g_pEventLoopManager->{addTimer, removeTimer}`,
  `Time::steadyNow`. Behavior read from the v0.56.2 sources (data, see "Minimize (M2): mechanism").
- Behavior read from the installed 0.56.2 binary (`objdump -d` of the exported symbols; member offsets
  checked with `static_assert(offsetof(...))` against the headers), relied on by FR7, FR12, FR13:
  - `CWindow::updateWindowDecos()` returns at once when `!m_isMapped` or `isHidden()`, so a removal queued by
    `removeWindowDecoration` → `CWindow::removeWindowDeco` (push to `m_decosToRemove`) waits for the window
    to be mapped and visible again.
  - `CPluginSystem::unloadPlugin(plugin, false)` calls `pluginExit` first, then `removeWindowDecoration()` for
    every pointer in a copy of `CPlugin::m_registeredDecorations` (never pruned by Hyprland), then `dlclose`.
    `CCompositor::cleanup()` (normal exit) unloads every plugin this way.
  - `CInputManager::onMouseButton` emits `input.mouse.button` first; a cancelled event returns before
    `m_currentlyHeldButtons` is updated. Otherwise a press is appended to that list *before* it is
    dispatched, so a press a decoration consumes is recorded as held too; a release removes every entry
    of its button, and a release of a button not in the list is dropped. Button events are then
    dispatched by `processMouseDownNormal`: `CKeybindManager::onMouseEvent`, the decorations of
    `windowAt(pos, RESERVED_EXTENTS | INPUT_EXTENTS | ALLOW_FLOATING)` through `CWindow::checkInputOnDecos`
    (box contains point, no popup there), and finally `CSeatManager::sendPointerButton`. After a release
    that empties the list while `m_focusHeldByButtons` is set, pointer focus is recomputed.
  - `CInputManager::mouseMoveUnified`: while `m_currentlyHeldButtons` is not empty (and no drag-and-drop
    runs), pointer focus stays on the current pointer-focus surface whatever is under the pointer
    (`m_focusHeldByButtons`). A stale entry therefore pins pointer focus indefinitely.
  - `CInputManager::releaseAllMouseButtons` sends a release for every held button straight to the seat
    (no `input.mouse.button` event) and empties the list.
  - `CWLPointerResource::sendButton` logs `sendButton release on a non-pressed button` (with its source
    location) and sends nothing when that resource never got the press (`m_pressedButtons`).
  - `CInputManager::destroyPointer` does not release the buttons held by the removed device.
- Measured pitfalls: `Config::Actions::focus()` warps the cursor to the window middle when the pointer is
  on the titlebar (outside the client surface); with it, drags through `CLayoutManager::beginDragTarget` or
  `CKeybindManager::changeMouseBindMode` jumped by (middle − press point). The plugin now focuses through
  `focusState()` and moves the window itself (no snapping); Hyprland's drag path should be re-tested in M1.
- The decoration priority must be above the border's (10005 used): at 10000 the titlebar was placed
  outside the border.
- Appmenu (S5, read from the 0.56.2 headers, exported symbols checked with `nm -D /usr/bin/Hyprland`):
  `g_pCompositor->{m_wlDisplay, m_isShuttingDown}`, libwayland-server 1.26.0 `wl_global_{create, remove,
  destroy}`, `wl_client_get_credentials`, `CWLSurfaceResource::fromResource` and `m_events.destroy`,
  `Desktop::View::IView::resource()`, `Event::bus()->m_events.window.{open, close, destroy, active}`, glibc
  `dladdr`, `dlopen(RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE)`. Code generator: hyprwayland-scanner 0.4.6
  (`compositor/protocols/appmenu.xml`). Test fixtures: Qt 6.11.2 Widgets/DBus, wayland-scanner 1.26.0, gdbus.
- GCC 16.2.1, C++23. Lua 5.5 headers (Hyprland links `liblua.so.5.5`). GoogleTest 1.18.0 for tests.
- Quickshell 0.3.1 for the IPC spike.

## Degraded behavior (plugin missing, service missing)

- ABI mismatch: no hooks, one notification, no `grassfield` event, `hyprctl grassfield` unknown → the
  shell sees no capabilities and keeps client-side decorations (§5.6).
- Init failure: everything registered so far is torn down, one notification, same fallback.
- Minimize without the `minimize` feature (plugin absent, mismatched, or its hooks failed): the shell parks
  the window on `special:minimized` itself (no animation) and restores it from there; same hidden state, so
  windows minimized either way stay restorable after the plugin comes or goes.
- Minimize without a Dock (no shell, or no target rectangle): the shell sends an empty rectangle and the
  plugin minimizes/restores without animation; with no shell at all, the minimize button only posts
  `minimize-request` and nothing happens (there would be no way to restore the window).
- Without the `config` feature the double-click always zooms (the default).
- Without the `appmenu` feature (plugin absent, mismatched, or the global failed): no
  `org_kde_kwin_appmenu_manager` global, no `appmenu` events; the shell keeps T0 menus. Whoever owns
  `com.canonical.AppMenu.Registrar` (the bridge, step B) must not own it then: Qt would hide its in-window menu
  bars with nowhere to show them (S5 finding 4).

## Automated tests · Manual verification steps

Automated (L0): `compositor/build/grassfield-compositor-tests` — protocol JSON (wire format, escaping,
advertised features, config allowlist), button layout, hit-testing, title placement, double-click detection,
drag threshold and un-zoom box, theme values, pointer press ownership and gesture end (`PointerGesture.*`),
minimize logic (`Minimize*`: address parsing, target validation, aspect fit, Bézier easing, frames,
snapshot texture box on the same and on another monitor), appmenu logic (`Appmenu*`: bus name and object path
validation, registrations and their announcements; `Protocol.Appmenu*`: event JSON), event and log rate limits
(`TokenBucket.*`, `EventThrottle.*`, `LogLimiter.*`, `LogMilestone.*`, FR24). Shell side: `tests/unit/tst_minimized.qml`
(request builders, config allowlist, `movewindowv2` parsing). Lint (Q1): `compositor/build-direct.sh tidy`
(`compositor/.clang-tidy`). Soak (C1): `tests/compositor/soak.sh [seconds]` (see `compositor/README.md`).
Nested scenarios: `tests/compositor/minimize.sh [repeats]` (FR6, FR14–FR17), `tests/compositor/double_click_setting.sh` (FR8, FR16), `tests/compositor/zoom_restore.sh`
(FR8), `tests/compositor/input_consistency.sh [rounds]` (FR13), `tests/compositor/appmenu.sh [variants]`
(FR18–FR22, spike S5; fixtures `tests/fixtures/{menu-demo, fake-registrar, appmenu-client}`, built by
`tests/fixtures/build.sh`), `tests/compositor/event_flood.sh [requests...]` (FR24; needs grassfield-shell).

Manual (L1, nested only):

1. Build: `compositor/build-direct.sh`.
2. Start: `scripts/dev/nested-up.sh` (`config/hypr/dev.lua` loads `GRASSFIELD_PLUGIN` at parse time; a load
   from a `hyprland.start` callback would be ignored because Hyprland applies the config's plugin list right
   after parsing; fixed in commit eaa953c, the S2 shim is gone).
3. Log (`$XDG_RUNTIME_DIR/hypr/<nested instance>/hyprland.log`):
   `[grassfield] grassfield-compositor 0.3.0-s5 initialised on Hyprland v0.56.2 (commit …), ABI hash match`.
   Hyprland buffers this log: lines written after start-up can appear only much later.
4. `WAYLAND_DISPLAY=$(cat .dev/nested.wayland) setsid foot >/dev/null 2>&1 &`, then
   `scripts/dev/shot.sh titlebar GF-REF`.
5. IPC: `WAYLAND_DISPLAY=… HYPRLAND_INSTANCE_SIGNATURE=… timeout 10 qs -p spikes/s2-ipc/shell.qml`.
6. Pointer (`tests/tools/vpointer`, coordinates relative to an output): e.g.
   `scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 700 400 up`. Abandoned drag (FR7):
   `scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 800 350` (no `up`), then
   `scripts/dev/pointer.sh output GF-REF abs 1400 700 sleep 200 abs 300 300 click`: the window must not move.

## Performance (gates affected) · Accessibility · i18n

- C1: soak script `tests/compositor/soak.sh` (nested only). 2026-10-17, plugin 0.2.0-m2 (minimize, config,
  drag threshold / un-zoom): `tests/compositor/soak.sh 600` → PASS, exit 0 (600 s, 352 rounds: 352
  short-lived + 352 churn windows, 88 drags, 44 abandoned drags, 88 zoom pairs, 44 cancelled and 44 real close
  clicks, 44 minimize + Dock-restore pairs; nested Hyprland alive, RSS 151.6 → 159.8 MB, flat from round 100
  to the end, no core dump, 0 grassfield exceptions in the flushed log, 210 seat warnings as designed). Most
  soak minimize pairs ran without animation: the Dock rectangle of `Quickshell.screens[0]` (the resizable
  nested WAYLAND-1 window, resized by the owner's session layout during the run) was rejected (90 "no valid
  Dock rectangle" log lines). The animated path ran in `minimize.sh`: 20 + 60 rounds on fresh instances,
  42 animated minimizes and 47 animated restores (move → event ≥ 250 ms), 5 + 15 Dock clicks 120 ms after
  the minimize click (normally during its animation), 2 + 2 windows killed 100 ms after a minimize / restore
  click, PASS, no core dump. Shutdown (SIGTERM) right after a minimize
  click: `[grassfield] grassfield-compositor unloaded`, `Hyprland has reached the end.`, no core dump (that
  minimize had no animation, see above). Earlier, plugin at commit 62bd114 (FR13
  fix, button events never cancelled): `tests/compositor/soak.sh 600` → PASS, exit 0 (600 s, 319 rounds:
  319 short-lived + 319 churn windows, 91 drags, 46 abandoned drags, 92 zoom pairs, 45 cancelled and 45 real
  close clicks; nested Hyprland alive, RSS 150.4 → 165.9 MB, flat over the last 200 rounds, no core dump,
  0 grassfield exceptions). 168 seat warnings `sendButton release on a non-pressed button`: the releases of
  titlebar presses that ended outside a titlebar while a client had pointer focus, dropped by the seat as
  designed (FR13). `tests/compositor/input_consistency.sh 5` right after the soak, same instance → PASS.
  Earlier run (plugin at commit a475092, releases still cancelled on the bus): `soak.sh 1260` → PASS
  (758 rounds, RSS 151.7 → 158.5 MB), but that build had the held-button defect, which the soak does not
  detect. The 1 h and 8 h runs are scheduled: C1 stays NOT VERIFIED until the 8 h run passes. C2 (scripted
  degradation) not run.
  FR24 (event throttle, 2026-10-17): `soak.sh 1200` → PASS (711 rounds, 89 animated minimize pairs, RSS
  152.1 → 159.0 MB, no core dump, 0 grassfield exceptions) on the build before a tidy-only refactor of
  `CEventThrottle::due`/`drain`; on the final build `soak.sh 600` → PASS (354 rounds, 44 animated minimize pairs,
  RSS 152.3 → 160.6 MB, no core dump, 0 exceptions), `minimize.sh` 20 rounds PASS, `input_consistency.sh` PASS,
  `appmenu.sh` PASS, `event_flood.sh` PASS, `tests/integration/global_menus.sh` 26/26 PASS (a first run failed
  1 check: transient shell QML warnings in phase B, which runs without the plugin).
  Title textures are cached per window and rebuilt only when the title, scale or available width changes;
  drawing adds 6 rect pass elements and 1 texture per decorated window.
- Q1: `compositor/build-direct.sh tidy` must exit 0 with no diagnostics.
- Accessibility: titlebar buttons are compositor-drawn and not exposed to assistive technologies; keyboard
  equivalents exist (SUPER+W close, SUPER+ALT+F zoom).
- i18n: no plugin strings are shown except the degradation notifications (English, compositor-side).

## Known limitations (honest, user-visible gaps vs macOS)

- Minimize uses the "Scale" effect; there is no "Genie" warp.
- The animation shows a snapshot taken at the start: a window that changes while it animates (video) is
  frozen for 300 ms; translucent windows are drawn without their blur during the animation (Hyprland renders
  snapshots without blur).
- The Dock tile rectangle comes from the shell: each per-screen Dock registers a provider
  (`Compositor.registerDock`), minimize targets the tile of the window on the Dock of its own monitor
  (separator + 1 + the window's index in the minimized list), restore the window's current tile on the
  focused monitor's Dock. Rectangles are in global layout coordinates, as the plugin validates them.
- `animations:enabled = false` in the Hyprland config does not disable the minimize animation.
- A restoring window is transparent but still receives input during its 300 ms animation (as during
  Hyprland's own fade-in).
- No hover glyphs (×, −, +), no grey inactive-window buttons, no pressed state.
- Appearance is fixed to dark; light colors exist in `Theme.hpp` but are not switchable yet.
- Titlebar drags don't snap to screen edges or other windows (SUPER+drag still does).
- Client-side-decorated apps that ignore the server-side decoration request get a second titlebar.
- Long titles are clamped to the available width by Hyprland's text renderer; ellipsis behaviour depends on it.
- The content's rounded top corners are filled with the titlebar color; with `rounding_power` 2.6 a small
  corner curve of the content stays visible instead of a perfectly square joint.
- The titlebar sits above the client's requested position, so a centered window's titlebar extends 28 px
  above the centered area.
- Fractional scaling: geometry is scaled by the monitor scale but only scale 1 was tested.
- Runtime unload (`hyprctl plugin unload`, needs `scripts/nestctl`) is untested; unload at compositor exit
  is tested.
- The release of a titlebar press that ends outside a titlebar (a button press moved away, a double-click
  zoom, and most fast drags, because the bar lags the pointer while the window's move animation runs) is
  processed by Hyprland like any release and reaches the seat, which drops it because the client never got
  the press. When a client surface has pointer focus at that moment, Hyprland logs `sendButton release on
  a non-pressed button` (log noise only). Until 2026-10-17 the plugin cancelled these releases on the event
  bus instead; Hyprland then kept the button as held and pinned pointer focus to the dragged window, so
  motion over other windows reached nothing and the next click on another window was delivered to the
  dragged one (counter-review finding, reproduced by `tests/compositor/input_consistency.sh`; an earlier
  version of this section wrongly stated that the next click was correct).
- Appmenu: only Wayland clients that implement `org_kde_kwin_appmenu` (Qt 6.11, Chromium 152) and only when
  `com.canonical.AppMenu.Registrar` is on their bus at start-up; X11 apps, GTK and Electron apps are not covered
  (T0 menus). The plugin only links windows to DBusMenu addresses; reading and showing the menus is step B.
- Appmenu runtime unload with client objects alive keeps the plugin library in memory (FR23): a rebuilt plugin
  at the same path loads only after Hyprland restarts; those clients' menus are not re-announced by a reloaded
  plugin until they create new appmenu objects.
- Window addresses are reused by Hyprland after a window is destroyed (seen in S5 runs): the shell must apply
  `appmenu` events in order, and a clear always precedes a reuse.
- Hyprland itself never releases the buttons of a removed pointer device: after an abandoned drag (device
  destroyed with the button down) it keeps that button as held until that button's next release, with or
  without the plugin. The plugin only ends its own gesture (FR7).
