# grassfield-compositor spec · compositor-engineer · M0 spike S2 → M1 decorations → M2 minimize → S5 appmenu → M3 overview v2 → desktop focus

Status: titlebars, gfc/1 capabilities, minimize/restore with animation (M2), the `config` verb
(double-click setting), the appmenu protocol server (feature 3, step A of global menus; spike S5), the overview
live transforms (feature 4, Mission Control v2: the plugin side; spike and shell contract in `docs/specs/overview.md`;
R13 fixes 2026-10-18) and the desktop focus policy (feature `desktop-focus`, FR30-FR32, ADR-0012 amendment; v2
`desktop-focus-v2`) implemented; Stages prototype behind a feature flag (features `stages-available` / `stages`,
FR33-FR38, ADR-0013, spec `docs/specs/stages.md`; input guards after the R13 review of 46b3e9b; active window, menus
and focus reasons after the R13 counter-review of 17208af; no focus under an Exclusive layer after the R13 counter-review #3 of e9ebc7f); cursor
refresh for the pointer size (feature `cursor-refresh`, FR39-FR40, ADR-0014); the focus after the Overview closes (feature
`overview-focus`, FR41-FR43, owner decision 2026-10-19 batch 5; its deferred-focus core shared with Stages). Plugin
0.8.2-clickfocus (click focus for Hyprland's focused window without the keyboard, FR30 (d); the keyboard back after an unlock, FR30 (e)).
Code: `compositor/`. Build and run: `compositor/README.md`.

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)

- Every standard window has a titlebar strip about 32 pt tall that is part of the window: same corner
  radius as the window at the top, square joint with the content, one continuous outline and shadow.
  Titlebar-only windows have a corner radius of about 13 pt; toolbar windows about 26 pt
  (docs/testing/f1-reference-gaps.md, "Window chrome").
- Three circular buttons on the left, 14 pt diameter, evenly spaced (9 pt gaps, 23 pt pitch), the first centre
  about 15.6 pt from the window's left and top edges, vertically centered: close, minimize, zoom. Glyphs appear on
  hover; inactive windows show grey buttons.
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
mesh-deformed texture draw, which Hyprland's pass elements do not offer), inactive-state (grey) buttons, the
pressed-button state, appearance switching, tiled windows, CSD negotiation; for the overview: the layout, labels, Desktops bar and
input (the shell), transforming popups; for appmenu: reading or
rendering DBusMenu menus (that is `grassfield-menu-bridge` and the shell, step B, ADR-0008), the
`com.canonical.AppMenu.Registrar` service, X11 (XWayland) menus.

## Functional requirements (numbered, testable)

- **FR1** The plugin refuses to hook anything when `__hyprland_api_get_hash()` differs from
  `__hyprland_api_get_client_hash()`, logs the mismatch and shows one notification.
- **FR2** Every mapped floating window (not full screen, `decorate` rule not false, not X11
  override-redirect) gets a titlebar decoration 32 px (logical) tall above its content; tiled and
  full-screen windows get none (zero extents).
- **FR3** The titlebar background uses the window's corner radius and rounding power on its top corners,
  is square at the bottom, and fills the content's rounded top corners; the window border and shadow
  wrap titlebar + content.
- **FR4** Close, minimize, zoom buttons: 14 px circles, 9 px gaps (23 px pitch), first one 9 px from the left
  edge (centres at x 16, 39, 62), vertically centered (y 16); each is hit inside its circle grown by 1/6 of the
  diameter (2.33 px), and the gaps between the buttons stay drag area; colors from `compositor/src/core/Theme.hpp` (close `#E5534B`, minimize `#D9A93B`,
  zoom `#4FA64F`; background dark `rgba(40,40,44,1)` / light `rgba(236,236,238,1)`, dark in S2).
- **FR4b** Hover glyphs (macOS): while the pointer is over the group of lights (the box of the three hit circles,
  gaps included) of the topmost window under it, all three lights show their glyph: × close, − minimize, + zoom (the
  zoom action; macOS shows + for zoom and arrows for full screen). Glyph box 0.55 of the diameter (8 px at scale 1,
  centred on whole pixels at every scale), strokes 0.12 of the diameter with round caps, black at 50 % over the
  light; active and inactive windows alike. A window drawn by the overview or Stages, or whose input is blocked,
  shows none. Only the titlebars whose hover state changes are damaged.
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
  `config` Lua function registered; `appmenu` (FR18), `overview` (FR29), `desktop-focus` + `desktop-focus-v2` (FR31),
  `stages-available` (FR33), `cursor-refresh` (FR40) and `overview-focus` (FR43) likewise; `stages` only while its flag is on
  (FR33) (`["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","cursor-refresh","overview-focus"]`
  when everything works and the flag is off).
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
  per request. One exception with a budget of its own (20 lines, then 2 per second, held-back count appended): the
  Dock rectangle of each minimize ("minimize <hex>: toward the Dock rectangle x,y wxh", 0.6.4-stages), which tests read
  to click the tile the shell named; in a soak the shared budget was spent by titlebar and Stages lines.
- **FR25** `hl.plugin.grassfield.overview(json)`: one Lua string of at most 16 KiB, copied out of Lua with non-raising
  calls, parsed by a strict JSON reader (`core/Overview.*`): an object with `on` (bool) and `durationMs` (integer
  0..2000) required, `windows` (array of at most 64 objects `{"address","x","y","w","h"}`: address as in FR14, finite
  numbers, w and h ≥ 1, no address twice) required when `on` is true, optional `curve` (4 finite numbers, x in [0, 1],
  y in [-1, 2]); unknown keys are skipped, a key given twice, nesting deeper than 16, strings over 256 bytes, NaN /
  Infinity / out-of-range numbers and trailing characters are refused. A refused request changes nothing and posts the
  current state with `"reason":"invalid"`. Always returns `hl.dsp.no_op()`. Log lines go through the request log budget
  (FR24).
- **FR26** For `on:true` each listed window is transformed only if it is mapped, not hidden, not pinned, on the active,
  non-special workspace of its monitor, not full screen and not on a workspace that shows a full-screen window
  (`FSMODE_FULLSCREEN`; maximized is allowed; decision 2026-10-18: on macOS a full-screen app is a Desktop of its own, and
  Hyprland draws only the full-screen window on its workspace) and its rect lies inside that monitor (1 px tolerance);
  other entries are ignored (logged). If windows were listed and none qualifies, nothing changes and the current state is
  posted with `"reason":"no-windows"`. Windows are transformed only while the shell's chrome covers them (R13 fix, relaxed
  2026-10-18): every monitor of the qualifying windows has a mapped layer surface with namespace `grassfield-overview`
  (any keyboard interactivity), and the seat keyboard is on such a surface (or one of its popups) whose interactivity is
  `Exclusive` (the focused output's; with every chrome Exclusive, Hyprland refused to give the keyboard back after the
  close on two outputs); otherwise nothing changes and the current state is posted with `"reason":"no-chrome"`. A
  transformed window gets a
  `Render::IWindowTransformer`; the window's main pass (surface, subsurfaces, decorations) is drawn, live, with its
  surface box fitted (uniform scale, centred) into its rect, decorations scaled with it. The client is never resized
  or configured and its window geometry never changes. Popups are not transformed. Snapshots (close / minimize
  animations) and window captures (`RPT_EXPORT`) show the window untransformed; on another monitor a spanning window
  is not drawn.
- **FR27** Windows animate from their live box to their rect (opening) and back from where they are drawn to their
  live box (closing) over `durationMs` with the cubic-bezier `curve` (default 0.2, 0, 0, 1 = the shell's
  `Tokens.motionCurveStandard`), interpolated every frame by the plugin (no per-frame IPC); `durationMs` 0 jumps to the
  end state. `on:true` while open, opening or closing retargets: listed windows continue from where they are drawn,
  windows no longer listed go back at once. Events (FR24 channel `overview`, one key):
  `{"v":"gfc/1","type":"overview","state":"opening|open|closing|closed","windows":N}` with `"reason"` when a request is
  refused (`invalid`, `no-windows`, `no-chrome`), the plugin unloads (`unavailable`), the overview is interrupted
  (`interrupted`) or a window went full screen while shown (`fullscreen`, state unchanged). A window leaving the
  overview while it is shown posts the current state again with the new count.
  A 150 ms watchdog after the expected end completes an animation when no monitor renders.
- **FR28** Damage: each animation tick (`render.preChecks`) damages every window's previous and new visual box (with
  every decoration extent). While an overview is shown, every frame of a monitor that has damage also redraws that
  monitor's layout boxes (added to its damage ring from `render.pre`); without damage no frame is rendered. The box
  drawn in a frame becomes the window's last damaged box (`core damageStep`, R13 fix): a surface resized while open has
  every box it was drawn in damaged again when it leaves it, and the box damaged at detach is the one drawn last. The
  first frame of each such resize burst is logged at debug level (request log budget).
- **FR29** Failsafes and cleanup: a window that closes, leaves its workspace or becomes pinned leaves the overview at
  once; a window becoming full screen takes every window of its workspace out at once (`fullscreen`). A mapped window
  that takes the keyboard from the chrome with a user or other focus reason, or the keyboard leaving the chrome, starts
  the closing animation (`interrupted`); Hyprland moving focus because a window closed or opened does not (the overview
  stays, the shell retargets; Hyprland 0.56.2 emits `window.active` for the closing window itself, reason "other", while
  it refuses the keyboard to the next window because of the Exclusive chrome: measured). A layer surface with namespace
  `grassfield-overview` closing while windows are shown (opening, open, or an interrupted closing) ends the overview at
  once without animation (`interrupted`); a closing the shell asked for runs to its end. A workspace switch that hides a
  transformed window, a monitor removal or a monitor layout change puts every window back at once (`interrupted`).
  `PLUGIN_EXIT` removes every transformer it attached (none may outlive `dlclose`), damages their boxes and posts
  `closed` with `"reason":"unavailable"` before the event throttle stops. Feature `overview` is advertised only when the
  listeners and the Lua function registered.
- **FR30** Desktop focus policy (feature `desktop-focus`, ADR-0012 amendment; contract `docs/specs/desktop.md`
  "Compositor focus policy"): on a pointer button press (event bus `input.mouse.button`, observed, never cancelled,
  FR13), with the press target = the seat's pointer focus resolved to its window or layer surface (subsurfaces climbed,
  popups to their owner; a Grassfield titlebar under the pointer counts as its window). When that pointer focus is
  missing or stale (no surface, a destroyed surface, or one whose view is unmapped or invisible: Hyprland 0.56.2 updates
  pointer focus on motion only, so a click right after a popup closed still finds the popup), the target is the surface
  under the cursor, looked up in Hyprland's pointer focus order (layer popups, Overlay, Top, windows with their popups,
  surfaces and titlebars, Bottom, Background; a window border outside its titlebar and surface counts as nothing; shell
  integration finding, main 9e76bd7). (a) A press on a normal window while the seat keyboard is on a
  `grassfield-desktop-icons` layer surface (any output) gives that window the keyboard through Hyprland's own click focus
  only (`Desktop::focusState()->fullWindowFocus(w, FOCUS_REASON_CLICK)`, which applies `no_focus`, modal children, the
  lock and Exclusive layers); a refusal leaves the keyboard where it is and is logged once (request log budget). The
  surface focus is never forced (R13 review of 5706cbd: the former `rawSurfaceFocus` fallback could bypass such rules).
  (b) A left press on such a desktop surface gives it the keyboard at once when its committed interactivity is
  `on_demand`, else on its first `on_demand` commit within 1000 ms (`CLayerShellResource` commit listener per desktop
  surface). The waiting grant is dropped by any later press and by any other focus change first: a keyboard focus change
  (`input.keyboard.focus`), a window activation (`window.active`, any reason), a window mapping (`window.open`), a
  workspace switch (`workspace.active`) (R13 review of 5706cbd: a late commit must not take the keyboard from what a key
  binding, a dispatch, a new window or a workspace switch chose). (c) Nothing else: no hover handling, presses on other
  `grassfield-*` layers, on popups, during a keyboard grab, an Exclusive layer or the session lock change nothing.
  (d) Click focus for Hyprland's focused window (real-session bug 2026-10-20, packages 0.4.0-3, plugin 0.8.1-clickfocus):
  a press on the window Hyprland counts as its focused window (`Desktop::focusState()->window()`) while the seat keyboard
  is not on it (its surface, a subsurface or one of its popups) gives it the keyboard, any button, with the same refusal
  rules as (a). Hyprland 0.56.2 refocuses on a click only when the clicked window is not its focused window; after a
  session unlock with the pointer off the windows (desktop, menu bar) it keeps its last window focused while the keyboard
  is on no surface, so a click on that window did nothing (`tests/compositor/click_focus.sh lock`). When Hyprland's focus
  state still names the window's surface, `fullWindowFocus` returns early: the state is reset first
  (`CFocusState::resetWindowFocus`) and the focus made again (`gf::deferredFocus::focusWindow`, shared with the
  titlebar; never while Hyprland refuses window focus). The titlebar's own press focus (FR7) tests the keyboard holder,
  not `isWindowActive`. A grant that does not give the keyboard is logged with the reason the plugin can tell: no keyboard
  device on the seat, window focus refused now (lock or Exclusive layer, the plugin then asks nothing), else Hyprland's
  own rules (`no_focus`, a modal child). (e) The keyboard back after an unlock (macOS model, plugin 0.8.2): on
  `CSessionLockManager::m_events.unlock` a refocus is armed for 1000 ms and tried from the event loop: when no surface
  holds the keyboard, Hyprland's focused window (mapped, visible, on a shown Desktop) gets it through the same shared focus,
  reason `FOCUS_REASON_OTHER`. Never while locked, never past an Exclusive layer, never from a holder: a window or layer
  surface that has the keyboard ends it; the lock surface, still alive a moment after the unlock, is waited out (retried
  every 50 ms: its destruction drops the keyboard without any focus event, measured). A press, a new lock or the end of the
  window cancels it; `stop()` removes its event-loop callback and timer. Hyprland 0.56.2 alone refocuses at the cursor only,
  so with the pointer on the desktop or the menu bar the keys typed after an unlock reached no window.
  Decision logic pure (`core/DesktopFocus.*`: press table, target source, pending grant, unlock step).
- **FR31** `desktop-focus` is advertised only when its listeners registered. `PLUGIN_EXIT` removes the button, layer,
  commit and focus listeners and any pending grant before the other teardown steps; the keyboard stays where it is.
- **FR32** Withdrawal: after every hook is removed, `PLUGIN_EXIT` posts `{"v":"gfc/1","type":"capabilities","features":[]}`
  directly (not throttled), so the shell returns to its fallbacks for every feature.
- **FR33** Stages flag and capabilities (`docs/specs/stages.md` ST1-ST2): `config("stagesEnabled", "true"|"false")`
  (exact strings, off at every load; turning it off ends Stages at once); `stages-available` when the Stages listeners,
  `hl.plugin.grassfield.stages` and `config` registered; `stages` only while the flag is on; a flag change re-posts the
  capabilities.
- **FR34** `hl.plugin.grassfield.stages(json)`: one Lua string of at most 8 KiB, copied out of Lua with non-raising calls,
  parsed by the strict JSON reader (`core/Json.*`, shared with FR25) and validated by `core/Stages.*` (ops `on`, `off`,
  `activate`, `merge`, `move`; limits in the spec's contract item 3); refused while the flag is off (`disabled`), when a
  strip's monitor, surface or input region does not cover its tiles (`no-strip`), when a stage or window does not exist
  (`unknown`), or when invalid (`invalid`). Always returns `hl.dsp.no_op()`; log lines through the request log budget.
- **FR35** Stages model and drawing (ST3-ST16): the model lives in the plugin (per workspace, recency order, grouped by
  window class); windows of strip stages stay mapped at their real places, are drawn live into their tiles by a
  `Render::IWindowTransformer` (drawing shared with the overview, `WindowTransform.*`) and get the plugin's input block
  reason (`CWindow::setInputBlocked`, bit `1 << 6`), so Hyprland's hit test skips them; no client is moved, resized or
  configured; swaps animate over the `durationMs`/`curve` of the latest `op:on`; Hyprland's window, focus, workspace,
  layer and monitor events keep the model in step (applied through one coalesced `doLater` per event loop pass, also for
  activate / merge / move requests: a dispatch causes at most one focus change).
- **FR36** Stages events: `{"v":"gfc/1","type":"stages","on":bool,"monitors":[…]}` (FR24 channel `stages`, one key), with
  `reason` as in FR34 plus `interrupted` (a strip surface went away or the monitors changed: that monitor's windows are
  shown normally at once) and `unavailable` (unload). Since 0.6.4-stages each monitor also names the front window of the
  shown Desktop's active stage and its app (`"front":{"address","app"}`, additive; app sanitized to valid UTF-8, at most
  256 bytes), re-posted when it changes: the menu bar's source while Hyprland has no active window (ST24).
- **FR37** Stages cleanup: `PLUGIN_EXIT` (and turning Stages off) removes every Stages transformer before `dlclose` and
  lifts every input block, removes the pending `doLater` callbacks (model sync, pointer refresh) and the watchdog timer,
  and posts `on:false`/`unavailable` before the event throttle stops; `start()` resets the flag and the model (the library
  may have stayed mapped since a previous load, FR23).
- **FR38** Stages input guards (ST6, ST9, ST10, ST23; R13 review of 46b3e9b): no pointer, scroll or key event reaches a
  strip window. Whenever a block changes the plugin re-runs Hyprland's pointer focus logic at the cursor
  (`CInputManager::simulateMouseMovement` plus a pointer frame; from the event loop inside layer-unmap and monitor paths;
  skipped while no pointer device exists, since Hyprland then refuses any pointer focus change); its first pointer button
  listener (`main.cpp`, before the titlebar and desktop focus code) and a scroll listener refresh a pointer focus still on
  a strip window, or clear it while a held button pins it there; a key listener applies a pending sync and moves a
  keyboard focus still on a strip window to the active stage's front window, or to nothing. Button events are never
  cancelled. When the focused window leaves the active stage (close, minimize, move) Hyprland's successor keeps the
  keyboard only if it may hold it; otherwise the active stage's front window, else nothing. Hyprland's `FFM` focus of a
  strip window (restoring its last window) does not bring its stage forward. The desktop focus policy counts a pointer
  focus on a window that does not take input as stale. Decision logic pure (`core/Stages.*`: `beforePointerEvent`,
  `keyboardAfterLeave`, `stripFocusBringsStage`; `core/DesktopFocus.*`: `classifyPointerFocus`). A transformed window
  without a free work buffer is drawn as nothing that frame (`WindowTransform.cpp`), never at its real place.
  R13 counter-review of 17208af (ST24, ST6 menus, ST10): Hyprland's active window is never a strip window (checked after
  every retarget and before every key); a menu (popup grab) of a window going to the strip ends as a click outside it
  would (`CSeatManager::setGrab(nullptr)`); only real user focus reasons bring a strip stage forward (reasons mapped one
  to one, `focusOrigin`; `WORKSPACE_CHANGE` is a restore only for the workspace's last focused window). R13
  counter-review #3 of e9ebc7f (ST23, ST24): while Hyprland refuses window focus (an Exclusive layer is mapped, the session
  is locked) the plugin requests none and changes none of Hyprland's lists: a strip window is cleared from Hyprland's
  active window (`CFocusState::resetWindowFocus` plus Hyprland's "no active window" notifications, keyboard holder,
  monitor, Desktop and special workspace untouched) and the incoming front window is focused once the layer released the
  keyboard, checked again then. Decision logic pure: `activeWindowAction`, `pendingFocusAction`, `focusOrigin`.
  R13 counter-review #4 of 0.6.3-stages (ST10 clicks, ST23, ST24): Hyprland reports `FOCUS_REASON_CLICK` for every
  refocus at the cursor (`CInputManager::refocus`, also when a layer unmaps with no active window), so a `CLICK` focus
  is a user choice only when a press caused it: the plugin records pointer button presses (its first button listener),
  touch downs and tablet tip/button presses before Hyprland handles them (`recordPress`, `clickFromPress`: a press
  counts while Hyprland handles it; with an Exclusive layer mapped, a press beside every Exclusive layer on a window
  counts for that window's refocus once the layer is gone). Hyprland's own pick while a focus is deferred neither drops
  it nor raises a window of the active stage; the deferred focus goes to the front window of the remembered Desktop's
  active stage (the remembered window, or the one in front now if it went away). Clearing the active window also runs
  `CWindowRuleApplicator::propertiesChanged(RULE_PROP_FOCUS)` and `CInputManager::recheckIdleInhibitorStatus`.
- **FR39** Cursor refresh (Settings › Accessibility › Pointer, ADR-0014; `docs/specs/settings.md` Pointer):
  `hl.plugin.grassfield.cursor_refresh()` (no argument; any argument is ignored and nothing is read from Lua; returns
  `hl.dsp.no_op()`) draws the pointer on screen again at the size Hyprland holds now. The shell calls it after its
  `setcursor <theme> <size>` was answered `ok`: Hyprland 0.56.2's `CCursorManager::changeTheme` loads the theme at the new
  size but leaves the image on screen until a client sets a shape again. The plugin re-applies the image Hyprland shows the
  way `IHyprRenderer::setCursorHidden(false)` does (read from the 0.56.2 binary):
  `IHyprRenderer::setCursorFromName(m_lastCursorData.name, true)` (same name, same shape index, image loaded again from the
  theme at its current size; the pointer position is not touched). Only when the decision (`core/CursorRefresh`, pure) is
  `redraw`: Hyprland renders the pointer (`shouldRenderCursor()`; a forced `setCursorFromName` bypasses Hyprland's hidden
  state, so it is never called while the pointer is hidden), the last image is not a client's own surface
  (`m_lastCursorData.surf` empty: a client surface carries its own image and size, and a client that hid its pointer with
  `wl_pointer.set_cursor` without a surface reads like this on 0.56.2), a named shape is recorded (no guessed default) and
  at least one monitor exists. Otherwise nothing is done (`hidden`, `client-surface`, `no-shape`, `no-output`).
- **FR40** Cursor refresh rate and lifecycle: the first request of a quiet period runs at once; requests within 25 ms of the
  last run are folded into one trailing run when the interval ends (a Hyprland event loop timer), so the last size is
  always drawn and a flood costs at most one run per 25 ms. Log lines through the request log budget: one when the outcome
  or the shape changes and at 1, 10, 100, … runs or folded requests. `cursor-refresh` is advertised when the Lua function
  registered and Hyprland's renderer exists; `PLUGIN_EXIT` removes the timer and the Lua function.
- **FR41** Overview close focus request (`docs/specs/overview.md` "Close focus"): `hl.plugin.grassfield.overview_focus(json)`,
  one Lua string of at most 512 bytes copied out of Lua with non-raising calls, parsed strictly (`core/OverviewFocus`:
  `{"target":"window","address":"0x…"}`, `{"target":"workspace","workspace":N}`, `{"target":"remembered","address":"0x…",
  "workspace":N?}`, `{"target":"none"}`, optional `"id"` 0..2^32-1; addresses 1-16 hex digits, not 0; workspaces 1..2^31-1;
  a field the target does not use, a key given twice or trailing text is refused; unknown keys skipped). A refused payload
  posts outcome `invalid` and changes nothing; a valid one replaces a waiting request and posts `pending`. Request log lines
  share the request log budget.
- **FR42** Overview close focus behaviour: the request waits while Hyprland refuses window focus (its Exclusive-layer list is
  not empty, read only; the shared `deferredfocus::mustWait`), tried from the event loop after every commit of a mapped layer
  surface (commit listeners on each `CLayerShellResource` while a request waits, and on layers that map meanwhile), a layer
  unmap, a keyboard focus change and the session lock, and synchronously before every key; bounded by 1 s (a timer: outcome
  `timeout`). Under the session lock: outcome `refused`, nothing focused. Once Hyprland accepts window focus the target is
  checked again: a named window that is mapped, not hidden, not on a special workspace and on a shown Desktop is focused with
  `CFocusState::fullWindowFocus(w, FOCUS_REASON_DISPATCH_FOCUSWINDOW)` (as `hl.dsp.focus({window = …})` after its Desktop
  switch, without its cursor warp); when Hyprland counts that window focused without the keyboard (its own focus attempt
  under the chrome was refused), `resetWindowFocus()` then the same focus again. A Desktop shown: its front window; not shown:
  `Config::Actions::changeWorkspace(ws)` (exported, the path of `hl.dsp.focus({workspace = …})`; never for the Desktop already
  shown, so `workspace_back_and_forth` cannot apply), then its front window; no window: Hyprland's active window and the
  keyboard cleared (`fullWindowFocus(nullptr)`, then `rawSurfaceFocus(nullptr)` if the keyboard stayed on a released chrome)
  unless an `on_demand` layer holds it, and that monitor focused. Fallback (window gone, minimized, hidden, not shown, Desktop
  missing, focus refused by Hyprland, target `none`): the front window of the remembered Desktop when shown, else of the
  Desktop on Hyprland's focused monitor, else no window. Front window: eligible windows (on the Desktop, mapped, not hidden,
  `acceptsInput()`, not `m_X11ShouldntFocus`) by their last focus since the load (`window.active`), then the stack top down
  (pure `frontOrder`); each candidate Hyprland refuses (a rule) is skipped. A press after the request (pointer button from the
  plugin's first button listener, touch down, tablet tip/button; `deferredfocus::recordPress` on the shared press context)
  beside every Exclusive layer on a window retargets to it; a press while Hyprland accepts window focus, or a `window.active`
  user choice of another window, ends the request (`superseded`). Events: channel `overview-focus` (FR24),
  `{"v":"gfc/1","type":"overview-focus","outcome":"pending|focused|fallback|timeout|refused|superseded|unavailable|invalid",
  "target":"…","id":N}` plus `address`, `workspace`, `reason`. Decision logic pure (`core/OverviewFocus`: `parseRequest`,
  `step`, `judgeWindow`, `plan`, `fallbackSpace`, `frontOrder`, `pressEffect`, `supersedes`, `eventJson`).
- **FR43** Overview close focus lifecycle and sharing: `overview-focus` is advertised when its listeners and the Lua function
  registered. `PLUGIN_EXIT` (before the event throttle stops) ends a waiting request with outcome `unavailable`, removes its
  listeners, commit watches, event-loop callback (`deferredFocus::CLater`) and timer; `start()` resets everything (the library
  may stay mapped, FR23). The deferred-focus core is shared with Stages: `core/DeferredFocus` (focus reasons and origins, press
  records, the refusal gate) and `DeferredFocus.*` (Hyprland's refusal checks, keyboard holder, cursor on an Exclusive layer,
  press context, reason mapping, coalesced event-loop attempt); Stages uses them unchanged (same conditions, order and doLater
  semantics; `gf::stages` keeps aliases).

## Acceptance criteria (each mapped to a test or scenario; level L0/L1/L2)

| FR | Test / scenario | Level | S2 result |
|---|---|---|---|
| FR1 | Code review of `PLUGIN_INIT`; scripted mismatch test (C2) | L0 / L1 | match path verified (log); mismatch path NOT VERIFIED |
| FR2 | nested: open foot → screenshot | L1 | verified (floating); tiled/full-screen hiding NOT VERIFIED |
| FR3 | nested screenshot, corner crops | L1 | verified at scale 1 (see limitations) |
| FR4 | unit `TitlebarLayout.*`, `Theme.*`; nested `tests/compositor/chrome.sh` (lights, bar, corners measured on GF-REF captures) | L0 / L1 | verified; F2a geometry (32-px bar, 14-px lights, 23-px pitch, first centre (16, 16); radius 26 for org.grassfield.*, 12 otherwise) 2026-10-22, Hyprland 0.56.2: `chrome.sh` PASS (lights within 0.05 px of their centres, 13.9 px across; 32 rows; corner insets 4 px (radius 12) and 8 px (radius 26)) |
| FR4b | unit `ButtonGroup.*`, `GlyphSize.*`, `GlyphMask.*`; nested `tests/compositor/chrome.sh` | L0 / L1 | 2026-10-22: glyphs on all three lights with the pointer between two lights (active window, inactive window, Settings), none with the pointer away |
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
| FR25 | unit `OverviewRequest.*`, `OverviewEvents.Json`; nested `overview.sh` check "invalid" | L0 / L1 | 2026-10-18 verified: 6 malformed payloads (missing fields, bad address, duration 99999, not JSON, 1e999, a number instead of a string) → `"reason":"invalid"`, state unchanged (`closed`), Hyprland alive; one Lua dispatch with 500 open/close pairs → 2 overview events posted, socket2 subscriber still connected, final state `closed`, windows at their place (run `run-20261018-003207`) |
| FR26 | unit `OverviewBounds.*`, `OverviewGeometry.*`; nested `overview.sh` check "sizes", "layout", "live", "invalid" (rect outside the monitor + unknown window → `no-windows`) | L0 / L1 | 2026-10-18 verified (run `.dev/overview/run-20261018-001222`): at/size of 6 windows identical before / during / after; terminal colour at 6/6 rect centres while open (1/6 before); the ticker's rect changed by 2233 px between two open frames, an idle window's by 0 px |
| FR27 | unit `OverviewTiming.*`, `OverviewGeometry.Interpolation*`; nested `overview.sh` check "events", frames during the 900 ms animations | L0 / L1 | 2026-10-18 verified: `opening` (6) → `open` (6), `closing` (6) → `closed` (0); a frame 250 ms into opening differs from before (214400 px) and from open (64237 px) |
| FR28 | nested `overview.sh perf 30` (9 windows) | L1 | 2026-10-18: open idle 0.3 % Hyprland CPU, open with one terminal printing 10 lines/s 6.4 % (3.7 % closed), continuous open/close 12.2 % (docs/specs/overview.md "v2 spike" (d)) |
| FR29 | nested `overview.sh` check "failsafe", "restore", "unload" | L1 | 2026-10-18 verified: fixture surface closed → `closing`/`closed` `interrupted`; after `on:false` the output matched the frame before (0.35 px, menu bar masked); `scripts/nestctl plugin unload` during an open overview: rc 0, Hyprland alive, windows back at their place, `closed`/`unavailable` posted; `plugin load` again → features include `overview` |
| FR26-FR29 (R13 fix) | unit `OverviewEvents.NewReasons`, `OverviewFocus.*`, `OverviewChrome.*`, `OverviewDamage.*`; nested `overview.sh` check (29 checks) | L0 / L1 | 2026-10-18, plugin 0.5.0-df, run `.dev/overview/run-20261018-085303`: **29/29 PASS** (the f12f610 script had 20 checks, not 21). On:true without the chrome → `no-chrome`, no `opening`; chrome mapped with keyboard None → `no-chrome`; closing the active window while open → no `closing`, `open`/6 posted, terminal grey at 6/6 remaining rects; a window going full screen → `open`/0 `fullscreen`, then on:true → `no-windows`; resize while open: damage log `open box height 351, box damaged at the start of the shrink 491` (with the fix reverted, run `run-20261018-084158`: `none`, FAIL; captures show no stale pixels either way); chrome unmapped (process alive) → `closed`/`interrupted` with no `closing`; chrome keyboard → None → `closed`/`interrupted`; process exit → `closed`/`interrupted`; flood and unload with the chrome mapped PASS |
| FR30-FR32 | unit `DesktopFocusPolicy.*`, `DesktopFocusLayers.*`, `DesktopFocusGrant.*`, `Protocol.WithdrawnCapabilitiesHaveNoFeature`; nested `tests/compositor/desktop_focus.sh` (`check`, `baseline`) | L0 / L1 | 2026-10-18, plugin 0.5.0-df, run `.dev/desktop-focus/run-20261018-085225-check`: **21/21 PASS**: last active foot clicked while the desktop holds the keyboard gets the keys; click the desktop then type at once 5/5 to the desktop; hover Dock / menu bar / a window and presses on Dock / menu bar keep the keys on the desktop; last active foot on the other output gets the keys; menu grab untouched (keys to the menu, Esc back to the desktop, outside click swallowed, next click on that foot works); unload while the desktop is focused: rc 0, empty capabilities posted, keys still reach the desktop, a click on another foot works, reload advertises `desktop-focus` and the policy works. All 22 window grants worked with `fullWindowFocus` alone (the `rawSurfaceFocus` fallback was not needed), 0 "NOT granted". `baseline` (plugin unloaded, run `run-20261018-080056-baseline`): the three review defects reproduce (keys typed after clicking the last active foot reach the desktop, also across outputs; 0/5 keys reach the desktop when typed right after its click) |
| FR30 (R13 minors + shell finding, 2026-10-18) | unit `DesktopFocusGrant.*` (focus events cancel or fulfil a waiting grant), `DesktopFocusTarget.*` (stale or missing pointer focus falls back to the surface under the cursor); nested `desktop_focus.sh` cases 7 and 8 (`check`, and `race` / `stale` against any loaded build) | L0 / L1 | Baseline plugin e066a19 (loaded with `nested-up.sh --no-plugin` + `scripts/nestctl plugin load`): `stale` FAIL (`desktopA=pf`: the click on the foot after menu → pointer onto the foot → Esc left the keys on the desktop), `race` 1/4 (run `run-20261018-135258-race`: the late `on_demand` commit took the keyboard from the window a focus dispatch
had just focused, 7a `desktopA=ka`, and from a new window, 7b `desktopA=kn`; 7c PASS. An earlier 7a used ALT+TAB, which is
not bound for the virtual keyboard in nested: foot received `ESC TAB`). Fixed build: `desktop_focus.sh check` **26/26 PASS** (runs `.dev/desktop-focus/run-20261018-121710-check`, `run-20261018-142147-check` on the final 0.6.0-stages build), `race` 4/4 (plugin log `cancelled (keyboard focus moved)`, `cancelled (window opened)`). The `rawSurfaceFocus` fallback is removed; `no_focus` windows are skipped by Hyprland's hit test, so the refusal path is reached only for rules applied while the pointer rests on a window (not exercised) |
| FR30 (d) (real-session click bug, 2026-10-20) | unit `DesktopFocusPolicy.PressOnHyprlandsFocusedWindowWithoutTheKeyboardFocusesIt`, `.HyprlandsFocusedWindowThatHasTheKeyboardOrCannotTakeItIsLeftAlone`, `.HyprlandsFocusedWindowWaitsForLockGrabAndExclusiveLayers`; nested `tests/compositor/click_focus.sh check` (and C2 with the plugin unloaded) | L0 / L1 | 2026-10-20/21, plugin 0.8.1-clickfocus, Hyprland v0.56.2 (efb50993): unit 235/235; `click_focus.sh` clients **14/14** (foot, Qt grassfield-settings, GTK4 nautilus, Chromium and Electron obsidian on Wayland, Chromium on XWayland: content and titlebar) and unlock **6/6** (pointer on the desktop, the bar, the window; content and titlebar; plugin log `press (button 0x110) on window … (pointer focus, Hyprland's focused window) while the keyboard is on none -> keyboard to the window`). Pre-fix build 0.8.0-ovfocus (0a4fb5a, loaded from another path with `scripts/nestctl plugin load`): unlock with the pointer on the desktop or the bar **0/4** (keys lost, A stays Hyprland's active window), the owner's symptom. Regressions: `desktop_focus.sh` 26/26, `window_stacking.sh` PASS. The shell-timing cases (`closed`, `menubar`) depend on how fast the shell's commits land: in a loaded nested session (load 3.5 to 6.7 on 8 CPUs) a closed surface stayed mapped 0.1 to 8 s and some runs lost a case to that |
| FR30 (d)/(e) follow-up (R13 findings on 0f3adf7) | unit `DesktopFocusUnlock.*` (focus when no surface holds the keyboard, never from a holder, wait for the lock surface, never while locked or past an Exclusive layer, armed window); nested `click_focus.sh check` sections `layer` (on-demand layer fixture `tests/compositor/click-focus-fixture`) and `unlock` | L0 / L1 | 2026-10-21, plugin 0.8.2-clickfocus, Hyprland v0.56.2 (efb50993): unit 239/239; `unlock` **15/15** (keys back in A with no click, 0 lost letters, pointer on the desktop, the bar, the window; plugin log `after the unlock the keyboard was on no surface: window … -> keyboard to the window`); merged 0.8.1 (0f3adf7, loaded from another path): keys with no click **0/4** with the pointer off the windows (the click cases pass); `layer` 2/2 on 0.8.2 and 0.8.1, **0/2** on 0.8.0-ovfocus (0a4fb5a). A first 0.8.2 build without the 50 ms retry also failed 0/4: the attempt found the lock surface still holding the keyboard and no focus event followed its destruction |
| FR26 (relaxed chrome rule) | unit `OverviewChrome.*`; nested `overview.sh` two-output case | L0 / L1 | 2026-10-18, plugin 0.6.0-stages, runs `.dev/overview/run-20261018-130541` and `run-20261018-142052` (final build): **32/32 PASS**: chrome Exclusive on GF-REF and None on WAYLAND-1 → opens with 7 windows; a click at the WAYLAND-1 window's real place reaches nothing; after the close the previously active window gets the keys |
| FR33-FR37 | unit `Stages*`, `Protocol.StagesFeaturesFollowAvailabilityAndTheFlag`; nested `tests/compositor/stages.sh` (`check`, `perf`) | L0 / L1 | 2026-10-18, plugin 0.6.0-stages, run `.dev/stages/run-20261018-141943-check`: **40/40 PASS** (detail and CPU table in `docs/specs/stages.md`); plugin 0.6.1-stages run `.dev/stages/run-20261018-200428-check`: **45/45 PASS**; plugin 0.6.2-stages runs `.dev/stages/run-20261019-080913-check` (GF-REF only) and `run-20261019-082610-check` (two outputs): **51/51 PASS**; plugin 0.6.3-stages runs `run-20261019-140152-check` (two outputs) and `run-20261019-131100-check` (GF-REF only): **58/58 PASS** |
| FR38 (R13 review of 46b3e9b) | unit `StagesInput.*` (pointer guard decisions, keyboard after a leave, strip focus origin), `DesktopFocusTarget.PointerFocusOnABlockedWindowIsStale`; nested `stages.sh` 5b (click without motion after a swap), 7b (after a new window), 8b (swap under an Exclusive layer), 12b (minimize the only window of the active stage), 12c (`cycle_next` stays in the active stage); `minimize.sh stages`; `soak.sh 660 stages` | L0 / L1 | 2026-10-18, plugin 0.6.1-stages, Hyprland v0.56.2 (efb50993): stages.sh 45/45, `minimize.sh stages` PASS (O gets the keys after A, alone in the active stage, is minimized), soak PASS; the pre-fix build fbacf15 fails the 5b, 8b and 12b sequences (scratch probe, `docs/specs/stages.md` acceptance) |
| FR38 (R13 counter-review of 17208af) | unit `StagesInput.HyprlandsActiveWindowNeverStaysOnAStripWindow`, `StagesInput.OnlyRealUserFocusIsAChoice`, `StagesInput.ADesktopSwitchRestoringItsLastWindowIsNotAChoice`; nested `stages.sh` 8c (window actions after a swap under an Exclusive layer), 8d (strip menus), 8e (`WORKSPACE_CHANGE`) | L0 / L1 | 2026-10-19, plugin 0.6.2-stages: stages.sh 51/51 (twice); the pre-fix build b7f0c3d fails 8c (both checks) and 8d (the swap check) in the same session (`.dev/stages/run-20261019-081839-check`) |
| FR38 (R13 counter-review #3 of e9ebc7f) | unit `StagesInput.UnderAnExclusiveLayerTheActiveStripWindowIsOnlyCleared`, `StagesInput.ADeferredFocusWaitsForTheLayerAndIsCheckedAgain`, `StagesInput.HyprlandsActiveWindowNeverStaysOnAStripWindow`; nested `stages.sh` 8c (no window or monitor focus under an Exclusive layer, `close()` closes no window), 8f (special workspace), 8g (Desktop not shown), 8h (polkit-like dialog) | L0 / L1 | 2026-10-19, plugin 0.6.3-stages: stages.sh 58/58 on two outputs (three runs) and GF-REF only; the pre-fix build ffdef45 51/58 in the same session (8c, 8f, 8g, 8h first check; `.dev/stages/run-20261019-130127-check`, `run-20261019-130612-check`); `soak.sh 1260 stages` and `soak.sh 1260` PASS |
| FR36, FR38 (R13 counter-review #4 of 0.6.3-stages) | unit `StagesInput.ARefocusAtTheCursorWithoutAPressIsNotAClick`, `APressIsAClickWhileHyprlandHandlesIt`, `APressBesideAnExclusiveLayerChoosesTheWindowPressed`, `ADeferredFocusFallsBackToTheFrontWindowNow`, `StagesEvents.TheFrontWindowAndItsApp`, `ClientTextIsSanitized`; nested `stages.sh` 8i (refocus at the cursor over an unrelated window, the stage's back window, empty desktop; remembered window closed; a click beside the layer or just after it wins; `front` in the event) and 8c (a focus-matched window rule rechecked) | L0 / L1 | 2026-10-19, plugin 0.6.4-stages, Hyprland v0.56.2 (efb50993): stages.sh **66/66** on the headless pair GF-REF + GF-REF2 (`.dev/stages/run-20261019-165827-check`) and on GF-REF only (`run-20261019-170037-check`), WAYLAND-1 disabled; the pre-fix build 3a1a7a8 (0.6.3-stages) **60/66** in the same session (`run-20261019-170310-check`: 8c rule, 8i(a) both checks, 8i(b), 8i(d), 8i(e) just after); after the merge with cursor-refresh (plugin 0.7.1-stages): 66/66 on the pair (`run-20261019-174116-check`) and GF-REF only (`run-20261019-174322-check`); `soak.sh 1260 stages` PASS (735 rounds, 92 minimize/restore pairs through the Dock, Hyprland exit status 0 only at `nested-down.sh`); details in `docs/specs/stages.md` "Fix pass 4" |
| FR39-FR40 | unit `CursorRefresh.*` (12); nested `tests/compositor/cursor_refresh.sh check` / `baseline` / `stress` | L0 / L1 | 2026-10-19, plugin 0.7.0-cursor, Hyprland v0.56.2 (efb50993), theme grassfield-cursors: `check` **PASS** 3 runs (`.dev/cursor-refresh/run-20261019-153210-check` final): a still arrow over the desktop 15×21 → 29×41 → 57×82 → 15×21 px (heights ×1.95 / ×3.9, back to the identical first image, 0 px differ), a still I-beam over foot 10×20 → 20×40 → 38×78 → 10×20, w/h kept (arrow 0.71, I-beam 0.50), `cursorpos` unchanged, image anchored at the hotspot; foot's hide-when-typing pointer stays hidden after a size change and a refresh (plugin outcome `client-surface`), shown again by a motion at the size applied meanwhile; 30 calls at 10/s + a 1000-call flood: 2 runs for the flood, `1/10/100 request(s) folded` logged, same image; unload: features `[]`, the still pointer keeps 24 px; load: grows again. `baseline` on `nested-up.sh --no-plugin` **PASS**: `hyprctl grassfield` "unknown request", 0 `[grassfield]` log lines, shell "ready degraded", every size sent (`pointer /setcursor grassfield-cursors N`), no script error, the still pointer keeps 24 px at 48/96, also after desktop → Dock → desktop, and shows 96 after an I-beam round trip. `stress 880` next to `soak.sh 900`: 7499 calls, 250 size changes, 0 failed (see C1) |
| FR41-FR43 | unit `OverviewFocus*` (request validation, gate, target plan, fallback Desktop, front window order, presses, user focus, events, capability: 11), `DeferredFocus*` (3; the Stages cases run through the aliases); nested `tests/compositor/overview_focus.sh check` / `baseline` / `stress`; `stages.sh`, `overview.sh`, `desktop_focus.sh`, `minimize.sh`, `soak.sh` (C1) | L0 / L1 | 2026-10-19, plugin 0.8.0-ovfocus, Hyprland v0.56.2 (efb50993): `check` **66/66 PASS** on the headless pair GF-REF + GF-REF2, WAYLAND-1 disabled (`.dev/overview-focus/run-20261019-194052-check`, final build; `run-20261019-192909-check`): letters reach exactly the target for the window active at open (three release orders), a window on the other output (chromes mapped or unmapping), the current Desktop, a Desktop on the other output, another Desktop, a closed and a minimized target (fallback), a press beside the remaining chrome, a polkit-like dialog during the close (its field gets the letters, `timeout`; a short one: the target after it), the lock (`refused`, nothing typed, no window focused); invalid payloads, a 300-request flood (one outcome), unload while waiting (`unavailable`, reload advertises the feature). `baseline` (the verb a no-op): old build 0.7.1-stages and `--no-plugin` both **32/44**, safety PASS (`run-20261019-201004-baseline`, `run-20261019-200901-baseline`): the targets on the other output, another Desktop and the press get nothing, keys lost after a closed or minimized target. Regressions on the same builds: `stages.sh` **66/66** (pair, `.dev/stages/run-20261019-193039-check`; final build with GF-REF + WAYLAND-1, `run-20261019-200634-check`), `overview.sh` 32/32, `desktop_focus.sh` 26/26, `minimize.sh` PASS |
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
| shell → plugin | `hl.plugin.grassfield.overview("<json>")` | `{"on":bool,"durationMs":int,"curve":[x1,y1,x2,y2]?,"windows":[{"address":"0x<hex>","x","y","w","h"}…]}` (FR25-FR27) |
| plugin → shell | socket2 event `grassfield` (overview state) | `{"v":"gfc/1","type":"overview","state":"opening\|open\|closing\|closed","windows":N}` (+ `"reason"`: `invalid`, `no-windows`, `no-chrome`, `unavailable`, `interrupted`, `fullscreen`; FR27) |
| plugin → shell | socket2 event `grassfield` at unload (FR32) | `{"v":"gfc/1","type":"capabilities","features":[]}` |
| plugin (no verb) | feature `desktop-focus` (+ `desktop-focus-v2`): click-to-focus for the layer surface `grassfield-desktop-icons` on pointer presses | FR30; contract `docs/specs/desktop.md` "Compositor focus policy" |
| shell → plugin | `hl.plugin.grassfield.config("stagesEnabled", "true"\|"false")` | FR33 |
| shell → plugin | `hl.plugin.grassfield.stages("<json>")` | `{"op":"on"\|"off"\|"activate"\|"move"\|"merge",…}` (FR34; contract `docs/specs/stages.md`) |
| plugin → shell | socket2 event `grassfield` (Stages state) | `{"v":"gfc/1","type":"stages","on":bool,"monitors":[…]}` (+ `"reason"`; FR36) |
| shell → plugin | `hl.plugin.grassfield.cursor_refresh()` (feature `cursor-refresh`), after the shell's `setcursor <theme> <size>` was answered `ok` | the pointer is drawn again at that size, same shape, same place (FR39-FR40); no event |
| shell → plugin | `hl.plugin.grassfield.overview_focus("<json>")` (feature `overview-focus`) when the Overview starts closing | `{"target":"window"\|"workspace"\|"remembered"\|"none",…}` (FR41; contract `docs/specs/overview.md` "Close focus") |
| plugin → shell | socket2 event `grassfield` (overview focus outcome) | `{"v":"gfc/1","type":"overview-focus","outcome":"…","target":"…","id":N}` (+ `"address"`, `"workspace"`, `"reason"`; FR42) |
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
  intermediate size, the titlebar (fixed height) would not scale, and the layout would fight the animation.
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
  Desktop focus (FR30-FR32) and the overview R13 fixes, read from the 0.56.2 headers: `g_pSeatManager->{m_state.keyboardFocus,
  m_state.pointerFocus, m_seatGrab->m_keyboard}`, `CWLSurfaceResource::m_role` with `SURFACE_ROLE_SUBSURFACE` /
  `CSubsurfaceRole::m_subsurface` / `CWLSubsurfaceResource::m_parent`, `Desktop::View::CWLSurface::fromResource()->view()`,
  `IView::type()`, `CWindow::fromView`, `CLayerSurface::{fromView, m_namespace, m_mapped, m_monitor, m_layerSurface}`,
  `CPopup::{fromView, layerOwner, getT1Owner}`, `CLayerShellResource::{m_current.interactivity, m_events.commit}`,
  `Desktop::layerState()->layers()`, `Desktop::viewState()->hitTest().windowAt`, `Desktop::focusState()->{fullWindowFocus,
  rawSurfaceFocus}`, `g_pInputManager->{m_exclusiveLSes, getMouseCoordsInternal}`,
  `g_pSessionLockManager->isSessionLocked()`, `Event::bus()->m_events.{layer.opened, layer.closed, input.keyboard.focus,
  window.active (with eFocusReason)}`, `Fullscreen::controller()->getFullscreenModes(PHLWORKSPACE)`. Measured in nested
  (not read from sources): Hyprland emits `window.active` for a closing window (reason `FOCUS_REASON_OTHER`) while it
  refuses the keyboard to the next window because of an Exclusive layer ("Refusing a keyboard focus to a window because of
  an exclusive ls"); `fullWindowFocus` moves the keyboard to a window Hyprland already counts as focused when a layer
  surface holds it (22/22 presses in `desktop_focus.sh`).
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
- Overview (M3, read from the 0.56.2 headers; behavior read from the v0.56.2 sources as data, see
  `docs/specs/overview.md` "v2 spike"): `Render::IWindowTransformer` (`transform`), `CWindow::m_transformers`,
  `IHyprRenderer::{m_bRenderingSnapshot, m_renderData.{pMonitor, projectionType, damage}, bindTempFB, draw(CClearPassElement::SClearData),
  draw(CTexPassElement::SRenderData, CRegion), damageBox, damageWindow}`, `Render::RPT_MONITOR`,
  `CMonitor::{resources()->getUnusedWorkBuffer(), m_damage.{hasChanged, damage}, m_transformedSize}` (`resources()` is a
  weak pointer over a unique pointer: never `lock()`ed), `Fullscreen::controller()->getFullscreenModes`,
  `CWorkspace::{m_renderOffset, m_isSpecialWorkspace}`, `CWindow::{m_floatingOffset, m_pinned, getWindowMainSurfaceBox}`,
  `CLayerSurface::m_namespace`, `Event::bus()->m_events.{render.{preChecks, pre}, window.{close, destroy, moveToWorkspace,
  fullscreen, pin, active}, layer.closed, workspace.active, monitor.{removed, layoutChanged}}`.
- Stages (M5 prototype, read from the 0.56.2 headers; exported symbols checked with `nm -D /usr/bin/Hyprland`; behaviour
  read from the v0.56.2 sources as data, see `docs/specs/stages.md` "Spike results"): `CWindow::{setInputBlocked,
  acceptsInput, m_class, m_isFloating, m_pinned, isX11OverrideRedirect}` (`eWindowInputBlockReason` bits 0-2 used by
  Hyprland; the plugin uses `1 << 6`), `CViewHitTester::windowAt` (skips windows that do not accept input),
  `CLayerSurface::{m_layer, m_geometry, resource()}`, `SSurfaceState::{input, inputIsInfinite}`,
  `State::monitorState()->monitors()`, `CEventLoopManager::{doLater, removeDoLater}`, `Event::bus()->m_events.window.{open,
  floating}`. Input guards (FR38, plugin 0.6.1-stages): `CInputManager::simulateMouseMovement` (exported; re-runs
  `mouseMoveUnified` at the cursor), `CSeatManager::{m_state.pointerFocus, m_state.keyboardFocus, m_mouse, m_seatGrab,
  setPointerFocus, sendPointerFrame}` (`setPointerFocus` refuses and logs "BUG THIS" without a pointer device),
  `CWindow::{noInputBlockedReasonsBesides, isHidden}`, `CWorkspace::isVisible`, `CFocusState::{fullWindowFocus,
  rawSurfaceFocus}`, `Event::bus()->m_events.input.{keyboard.key, mouse.axis}` (observed, never cancelled),
  `Desktop::FOCUS_REASON_FFM` (what `CInputManager::refocusLastWindow` uses when a layer releases the keyboard). Plugin
  0.6.3-stages: `CFocusState::resetWindowFocus`, `CHyprXWaylandManager::activateWindow(w, false)`,
  `CWindow::updateDecorationValues`, `CEventManager::postEvent` (`activewindow` / `activewindowv2` with no window),
  `Event::bus()->m_events.window.active.emit(nullptr, …)` (as `CFocusState::rawWindowFocus` does for no window),
  `CWorkspace::isVisibleNotCovered`, `Event::bus()->m_events.input.keyboard.focus`; `CInputManager::m_exclusiveLSes` is
  only read (Hyprland's refusal condition) and `CLayerSurface::onUnmap` emits `layer.closed` before Hyprland's refocus
  (read from the v0.56.2 sources). Desktop focus v2: `CViewHitTester::{layerPopupSurfaceAt, layerSurfaceAt, windowSurfaceAt}`,
  `CMonitor::m_layerSurfaceLayers`, `State::monitorState()->query().vec()`, `IView::aliveAndVisible`. Plugin 0.6.4-stages
  (all exported, checked with `nm -D /usr/bin/Hyprland`): `CWindowRuleApplicator::propertiesChanged` with
  `Desktop::Rule::RULE_PROP_FOCUS`, `CInputManager::{recheckIdleInhibitorStatus, getMouseCoordsInternal}`,
  `CViewHitTester::windowAt` (Hyprland's press hit test flags) and `layerSurfaceAt` / `layerPopupSurfaceAt` on a copy of
  `m_exclusiveLSes`, `Event::bus()->m_events.input.{touch.down, tablet.tip, tablet.button}` (observed, never cancelled);
  read from the v0.56.2 sources: `CInputManager::refocus` is `mouseMoveUnified(…, refocus = true)` and reports
  `FOCUS_REASON_CLICK`; `refocusLastWindow` falls back to it when there is no active window on that monitor; the touch
  down, tablet tip and tablet button handlers emit their bus event before their own `refocus`.
- Cursor refresh (plugin 0.7.0-cursor, read from the 0.56.2 headers `render/Renderer.hpp`, `pointer/cursor/CursorManager.hpp`,
  `pointer/PointerManager.hpp`; exported symbols checked with `nm -D /usr/bin/Hyprland`; behaviour read from the stripped
  binary with `objdump -d`, no source used): `IHyprRenderer::{setCursorFromName(name, force), shouldRenderCursor(),
  m_lastCursorData.{name, surf}}` (public), `Pointer::Cursor::mgr()`, `Pointer::mgr()`, `State::monitorState()->monitors()`,
  `CEventLoopManager::{addTimer, removeTimer}`. `setCursorFromName`: sets `m_cursorHasSurface`; returns when the name is
  unchanged and not forced; assigns the name (self-assignment safe), updates the shape index (timer reset only when it
  changes), resets `surf`; returns when `m_cursorHidden` and not forced; then `CCursorManager::setCursorFromName(name)`
  (theme lookup at the size of the last `changeTheme`). `setCursorHidden(false)`: `surf` → `setCursorSurface(surf, hotspot,
  true)`, else a non-empty name → `setCursorFromName(name, true)`, else `setCursorFromName("left_ptr", true)`.
  `shouldRenderCursor()` = `!m_cursorHidden && m_cursorHasSurface` (both protected).
- Overview close focus (plugin 0.8.0-ovfocus, read from the 0.56.2 headers `desktop/state/FocusState.hpp`,
  `config/shared/actions/ConfigActions.hpp`, `protocols/LayerShell.hpp`, `managers/SessionLockManager.hpp`,
  `state/WorkspaceState.hpp`, `desktop/Workspace.hpp`; exported symbols checked with `nm -D /usr/bin/Hyprland`
  (`Config::Actions::focus`, `Config::Actions::changeWorkspace(PHLWORKSPACE)`); behaviour read from the binary with
  `objdump -d`, no source used): `Config::Actions::focus` runs `changeWorkspace` when needed, then
  `CFocusState::fullWindowFocus(w, FOCUS_REASON_DISPATCH_FOCUSWINDOW = 3)`, then `CWindow::warpCursor`; `changeWorkspace`
  focuses the monitor, `CMonitor::changeWorkspace`, its focus candidate, and may warp the pointer per config. Used:
  `CFocusState::{fullWindowFocus, resetWindowFocus, rawSurfaceFocus, rawMonitorFocus, window, monitor}`,
  `CLayerShellResource::m_events.commit`, `CSessionLockManager::m_events.lock`, `State::workspaceState()->query().id().run()`,
  `CWindow::{acceptsInput, isHidden, m_X11ShouldntFocus}`, `CEventLoopManager::{doLater, removeDoLater, addTimer, removeTimer}`.
  Measured in nested: Hyprland's successor focus of a window closed under the chrome logs "On closed window, new focused
  candidate is …", then "Refusing a keyboard focus to a window because of an exclusive ls", and leaves that window as its
  focused window without the keyboard (a later `fullWindowFocus` of it returns early: hence the state reset); a plugin load
  or unload reloads the config (its monitor rules enable WAYLAND-1 again); a plugin unloaded with appmenu clients alive stays
  mapped and a load of the same path gets the same library (FR23): test a rebuild in a new nested session.
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
- Without the `overview` feature (plugin absent, mismatched, or its listeners failed): `hl.plugin.grassfield.overview`
  does not exist and the shell keeps the v1 thumbnails. A refused request (`invalid`, `no-windows`, `no-chrome`) or an
  unload during an overview (`unavailable`) is reported in the `overview` event, so the shell can fall back for that open.
- Without the `desktop-focus` feature (plugin absent, mismatched, its listeners failed, or withdrawn at unload): Hyprland's
  own focus handling only; the shell keeps its kicker surface and pointer-leave drop and no file-changing desktop keys
  (ADR-0012 amendment). The unload posts a capabilities event with no feature (FR32) so the shell switches at once.
  Without `desktop-focus-v2` the shell keeps the file-changing desktop keys off (shell main 23caeab).
- Without `stages-available` (plugin absent, mismatched, its listeners failed): no Stages at all; Quick Settings hides the
  toggle. With it but the flag off: `stages` is not advertised and the verb refuses (`disabled`). A monitor without the
  shell's strip surface: its windows are shown normally.
- Without `cursor-refresh` (plugin absent, mismatched, an older plugin, or withdrawn at unload): the shell still sends
  `setcursor` and sends no refresh (`shell/platform/Pointer.qml` checks the capability; the call is guarded anyway); the
  pointer keeps its previous size until the shape name changes: entering another surface that sets the same shape
  (desktop → Dock, both `default`) is not enough, since `setCursorFromName` returns for an unchanged name. Measured:
  `tests/compositor/cursor_refresh.sh baseline` and the unload step of `check`.
- Without `overview-focus` (plugin absent, mismatched, an older plugin, its listeners failed, or withdrawn at unload): the
  verb does not exist (the shell's guarded call is a no-op) and the shell restores the focus after the Overview itself (checks
  and retries: `FocusReturn.startFallback`, docs/specs/overview.md "Close and keyboard"). An unload while a request waits posts outcome `unavailable` first. Measured:
  `tests/compositor/overview_focus.sh baseline` (an older build, a `--no-plugin` session) and case 14 of `check`.

## Automated tests · Manual verification steps

Automated (L0): `compositor/build/grassfield-compositor-tests` — protocol JSON (wire format, escaping,
advertised features, config allowlist), button layout, hit-testing, title placement, double-click detection,
drag threshold and un-zoom box, theme values, pointer press ownership and gesture end (`PointerGesture.*`),
minimize logic (`Minimize*`: address parsing, target validation, aspect fit, Bézier easing, frames,
snapshot texture box on the same and on another monitor), appmenu logic (`Appmenu*`: bus name and object path
validation, registrations and their announcements; `Protocol.Appmenu*`: event JSON), event and log rate limits
(`TokenBucket.*`, `EventThrottle.*`, `LogLimiter.*`, `LogMilestone.*`, FR24), overview logic (`Overview*`: payload
parsing and validation, bounds, timing, interpolation, texture box, event JSON, FR25-FR28). Shell side: `tests/unit/tst_minimized.qml`
(request builders, config allowlist, `movewindowv2` parsing). Lint (Q1): `compositor/build-direct.sh tidy`
(`compositor/.clang-tidy`). Soak (C1): `tests/compositor/soak.sh [seconds]` (see `compositor/README.md`).
Nested scenarios: `tests/compositor/minimize.sh [repeats] [stages]` (FR6, FR14–FR17; since 0.6.4-stages it clicks the
Dock tile the shell itself sent with the minimize, read from the plugin's log line "minimize <hex>: toward the Dock
rectangle x,y wxh" (a log budget of its own: 20 at once, then 2 per second) through `scripts/nestctl rollinglog -f`
(line-buffered with `stdbuf -oL`), never a position computed from the Dock layout; the Dock fix
pass 31458f5 (recents, dividers) had made the computed tile drift), `tests/compositor/double_click_setting.sh` (FR8, FR16), `tests/compositor/zoom_restore.sh`
(FR8), `tests/compositor/input_consistency.sh [rounds]` (FR13), `tests/compositor/appmenu.sh [variants]`
(FR18–FR22, spike S5; fixtures `tests/fixtures/{menu-demo, fake-registrar, appmenu-client}`, built by
`tests/fixtures/build.sh`), `tests/compositor/event_flood.sh [requests...]` (FR24; needs grassfield-shell),
`tests/compositor/overview.sh [check | perf [seconds]]` (FR25-FR29; fixture `tests/compositor/overview-fixture`),
`tests/compositor/desktop_focus.sh [check | baseline | race | stale]` (FR30-FR32; fixture `tests/compositor/desktop-focus-fixture`),
`tests/compositor/stages.sh [check | perf [seconds]]` (FR33-FR37; fixture `tests/compositor/stages-fixture`).
Unit tests also cover the desktop focus policy (`DesktopFocus*`: decision table, layer classification, pending grant,
press target source), Stages (`Stages*`: model, request validation, thumbnail geometry, events, flag) and the cursor
refresh (`CursorRefresh.*`: verb and feature names as the shell sends them, advertised list, decision table, log names,
rate gate). Nested: `tests/compositor/cursor_refresh.sh [check | baseline | stress [seconds]]` (FR39-FR40),
`tests/compositor/overview_focus.sh [check | baseline] [--plugin PATH]` (FR41-FR43; fixture
`tests/compositor/overview-focus-fixture`, the foreign locker `tests/security/foreign_locker/ForeignLocker.qml`). Unit tests
also cover the overview focus (`OverviewFocus*`: request validation, gate, target plan, fallback Desktop, front window order,
presses, user focus, events, capability) and the shared deferred focus (`DeferredFocus*`).

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
  Plugin 0.5.0-df (desktop focus + overview R13 fixes, 2026-10-18): `soak.sh 660` → PASS, exit 0 (log
  `.dev/soak-20261018-085426.log`: 391 rounds, 97 drags, 49 abandoned, 98 zoom pairs, 49 cancels, 49 closes, 49 minimize
  pairs all animated; RSS 152.3 → 160.6 MB, flat from round 100; no core dump; 0 grassfield exceptions; 224 seat
  warnings as designed); then on a fresh instance `desktop_focus.sh` 21/21, `overview.sh check` 29/29,
  `input_consistency.sh`, `minimize.sh`, `appmenu.sh`, `event_flood.sh` PASS, `tests/integration/global_menus.sh` 30/30
  PASS (phase B without the plugin). C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` unknown, shell log
  "no compositor plugin reply, running in degraded mode".
  Plugin 0.6.0-stages (desktop focus v2, relaxed overview chrome rule, Stages behind its flag, 2026-10-18): `soak.sh 660`
  → PASS, exit 0 (log `.dev/soak-20261018-131749.log`: 390 rounds, 97 drags, 49 abandoned, 98 zoom pairs, 49 cancels, 49
  closes, 48 minimize pairs all animated; RSS 152.4 → 159.4 MB, flat from round 100; no core dump; 0 grassfield
  exceptions; 224 seat warnings as designed; Stages flag off, its default); `desktop_focus.sh` 26/26, `overview.sh check`
  32/32, `stages.sh check` 40/40, `input_consistency.sh`, `minimize.sh`, `appmenu.sh`, `event_flood.sh` PASS,
  `tests/integration/global_menus.sh` 31/31 PASS. C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` "unknown request",
  `hl.plugin.grassfield` is nil (an unguarded call errors; the shell guards every verb), shell log "no compositor plugin
  reply, running in degraded mode".
  Plugin 0.6.1-stages (Stages input guards, R13 review of 46b3e9b, 2026-10-18, Hyprland v0.56.2 commit efb50993):
  `soak.sh 660 stages` → PASS with Stages on (log `.dev/soak-20261018-201156.log`: 372 rounds, 74 moves into new strip
  stages, 52 swaps, 1393 stages events, 46 minimize pairs all animated, 0 Dock clicks skipped and every one on the
  minimized foot tile; RSS 152.5 → 160.8 MB, flat from round 100; no core dump; 0 grassfield exceptions; 226 seat warnings
  as designed); Stages off: `desktop_focus.sh` 26/26, `overview.sh check` 32/32, `input_consistency.sh`, `minimize.sh`,
  `appmenu.sh`, `event_flood.sh` PASS; Stages on: `stages.sh` 45/45, `minimize.sh stages` PASS;
  `tests/integration/global_menus.sh` PASS (41 checks). C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` "unknown
  request", `hl.plugin.grassfield.stages(...)` errors (nil `grassfield`), no `[grassfield]` line in the nested log, shell
  log "no compositor plugin reply, running in degraded mode".
  Plugin 0.6.2-stages (Stages fix pass 2, R13 counter-review of 17208af, 2026-10-19, Hyprland v0.56.2 commit efb50993, host
  loaded by other agents' sessions, load average ~6): `soak.sh 360 stages` → PASS (log `.dev/soak-20261019-083846.log`:
  166 rounds, 33 moves into new strip stages, 23 swaps, 594 stages events, 17 minimize pairs all animated (3 skipped, no
  move seen); RSS 151.4 → 161.0 MB; no core dump; 0 grassfield exceptions; 86 seat warnings as designed). A first
  `soak.sh 360 stages` on another fresh instance ended at round 20 (`.dev/soak-20261019-082810.log`): the nested Hyprland
  vanished without a core dump, a crash report or a log line, a foot of the run was SIGKILLed at the same moment and
  xdg-desktop-portal-hyprland segfaulted on its lost connection; no OOM or systemd-oomd entry in the journal; cause not
  found (not reproduced). Stages on: `stages.sh` 51/51 (two runs, one with GF-REF only, one with GF-REF and WAYLAND-1),
  `minimize.sh stages` PASS; Stages off: `desktop_focus.sh` 26/26, `overview.sh check` 32/32 (a first run 31/32: the
  WAYLAND-1 probe window opened on GF-REF, the rerun passed). C2: `nested-up.sh --no-plugin` → `hyprctl grassfield`
  "unknown request", `hl.plugin.grassfield.stages(...)` errors (nil `grassfield`), 0 `[grassfield]` lines, shell log "no
  compositor plugin reply, running in degraded mode"; under an Exclusive layer `hl.dsp.window.close()` closes Hyprland's
  active window as usual (no Stages, nothing hidden).
  Plugin 0.6.3-stages (Stages fix pass 3, R13 counter-review #3 of e9ebc7f, 2026-10-19, Hyprland v0.56.2 commit
  efb50993, two outputs, host load ~2): `soak.sh 1260 stages` → PASS (log `.dev/soak-20261019-131315.log`: 764 rounds,
  152 moves into new strip stages, 108 swaps, 2579 stages events, 95 minimize pairs all animated, 0 skipped; Hyprland
  alive, RSS 161.0 MB from round 100 to the end; no core dump; 0 grassfield exceptions); `soak.sh 1260` with Stages off →
  PASS (`.dev/soak-20261019-133750.log`: 771 rounds, 96 minimize pairs, RSS 160.7 MB flat, no core dump, 0 exceptions).
  The Stages-on run used the build before the version-string change (code identical); the Stages-off run, the final
  `stages.sh` run and C2 used the 0.6.3-stages build.
  Plugin 0.7.0-cursor (cursor refresh, 2026-10-19, Hyprland v0.56.2 commit efb50993): `soak.sh 900` → PASS, exit 0 (log
  `.dev/soak-20261019-151502.log`: 546 rounds, 137 drags, 69 abandoned, 136 zoom pairs, 68 cancels, 68 closes, 68 minimize
  pairs all animated, 0 skipped; RSS 152.7 → 162.2 MB from round 100 to 500 → 160.8 MB at the end; no core dump; 0 grassfield
  exceptions; 320 seat warnings as designed) with `cursor_refresh.sh stress 880` running at the same time (7499 verb calls
  at 10/s, 250 `pointer.size` changes through the shell, 0 failed calls, `cursor-refresh` still advertised); then on the
  same build `overview.sh` 32/32, `desktop_focus.sh` 26/26, `minimize.sh` PASS, `cursor_refresh.sh check` PASS. C2:
  `nested-up.sh --no-plugin` → `cursor_refresh.sh baseline` PASS (FR39-FR40 row).
  Plugin 0.8.0-ovfocus (overview close focus, 2026-10-19, Hyprland v0.56.2 commit efb50993, GF-REF + WAYLAND-1): `soak.sh 1260`
  → PASS, exit 0 (log `.dev/soak-20261019-194150.log`: 732 rounds, 183 drags, 92 abandoned, 184 zoom pairs, 91 cancels, 91
  closes, 90 minimize pairs all animated, 1 skipped (no move seen); RSS 159.1 MB at rounds 600-700, 157.8 MB at the end; no
  core dump; 0 grassfield exceptions; 418 seat warnings as designed) with `overview_focus.sh stress 1200` running at the same
  time (4239 overview focus requests at ~4/s over the churned windows, 423 invalid, every one answered, `overview-focus` still
  advertised); `stress 180` alone afterwards: 647 requests, 2 floods of 100 each answered with one outcome. 0 i915 fence
  timeout or GPU hang lines in `journalctl -k` during the runs. C2: `nested-up.sh --no-plugin` → `hyprctl grassfield` "unknown
  request", shell "running in degraded mode", `overview_focus.sh baseline` safety PASS (FR41-FR43 row).
  **Nested Hyprland losses (C1 investigation).** The reviewer's `soak.sh 1260 stages` on e9ebc7f lost the nested Hyprland
  at round 554 (10:46:19). Findings: its log ends mid-stream with no shutdown line (a SIGTERM stop logs "Hyprland
  received signal 15" and "Hyprland has reached the end", as 60+ other nested logs of that day did), no crash report, no
  core dump, no kernel segfault or OOM line and no systemd-oomd action in the journal (previous boot, from 2026-10-18
  21:00); xdg-desktop-portal-hyprland segfaulted 0.5 s later inside `exit()` on its lost connection (a consequence, seen
  at every loss). Among the nested instances whose logs survived until the 11:31 power loss, five ended this way:
  2026-10-18 22:24 and 22:48 (another worktree, overview work, Stages never turned on), 2026-10-19 07:33 (a 9 s old
  instance, no Stages), 08:28 (fix pass 2's first soak, a foot of the run SIGKILLed at the same moment) and 10:46 (the
  reviewer). Two of five never used Stages, so the losses are not tied to Stages; a loss without any log line, core dump
  or crash report matches a SIGKILL from outside (the crash handler covers SIGSEGV/SIGABRT, SIGTERM is logged, an OOM
  kill is logged by the kernel). The sender of a SIGKILL is not recorded without root tools (audit, BPF): NOT identified.
  This pass ran each soak under a dev-only supervisor (scratch `.dev/fp3/supervise.py`, not tracked: it detaches from the
  agent's tools, makes itself the child subreaper and runs `nested-up.sh`, so Hyprland's wait status is recorded, and
  samples Hyprland every 10 s). Both 1260 s runs kept the nested Hyprland alive; it exited only at `nested-down.sh`,
  "exited with status 0". Samples (Stages on / off): RSS 151.2 → max 166.7 → 152.8 MB / 153.5 → max 166.4 → 152.5 MB after
  the run; fds 120 → max 177 → 141 / 128 → max 149 → 124; sockets back to 27 both times: no growth. The 11:31 stop was
  a power loss of the machine (external, not this pattern).
  Title textures are cached per window and rebuilt only when the title, scale or available width changes;
  drawing adds 6 rect pass elements and 1 texture per decorated window.
- Q1: `compositor/build-direct.sh tidy` must exit 0 with no diagnostics.
- Accessibility: titlebar buttons are compositor-drawn and not exposed to assistive technologies; keyboard
  equivalents exist (SUPER+W close, SUPER+ALT+F zoom).
- i18n: no plugin strings are shown except the degradation notifications (English, compositor-side).

## Known limitations (honest, user-visible gaps vs macOS)

- Stages (prototype behind a flag): limits and risks in `docs/specs/stages.md` "Known limitations and risks".
- Overview close focus (`overview-focus`): the shell sends it on every close (`Overview.closeAnd`) and keeps its own
  checked focus path without the capability. Keys typed before the last chrome released still reach that chrome (lost,
  as in the drop table of `docs/specs/overview.md`). The bound is fixed (1 s): a dialog open longer during the close ends the
  request (`timeout`) and Hyprland's own refocus decides when it closes. The activation order behind the front window starts
  at the plugin load (before it, and after a reload, the stack order is used). A touch or tablet press during the close counts
  as a press into the Exclusive layer (it never retargets). Stages on during a close focus was not exercised in nested.
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
  corner curve of the content stays visible instead of a perfectly square joint. Hyprland 0.56.2 rounds all four
  corners of the surface with one radius (`CSurfacePassElement` has no per-corner rounding), so at radius 20
  (org.grassfield.* windows) that curve is 20 px: a concave titlebar-coloured corner at the top of the content
  (`.dev/chrome/run-*/settings-corner-*-4x.png`). macOS joins titlebar and content square.
- The titlebar sits above the client's requested position, so a centered window's titlebar extends 32 px
  above the centered area.
- Fractional scaling: geometry is scaled by the monitor scale but only scale 1 was tested.
- Runtime unload through `scripts/nestctl` is exercised by `tests/compositor/overview.sh` (unload during an open
  overview) and `tests/compositor/desktop_focus.sh` (unload while the desktop holds the keyboard), each followed by a
  load (Hyprland alive, features back); the appmenu pinning path (FR23) is still not verified with client objects alive,
  so a rebuilt plugin is tested on a fresh nested instance, not by unload + load.
- Desktop focus (FR30): pointer button presses only (touch and tablet taps keep Hyprland's behaviour); a press on a
  window border outside its titlebar and surface is left to Hyprland; keys typed between a desktop click and the shell's
  `on_demand` commit (one frame) go to the previous holder.
- Overview: screen captures showed no stale pixels even with the FR28 fix reverted (most likely a capture repaints the
  whole output; not read from the sources), so the resize case is verified through the plugin's damage log and a unit
  test, not pixels; stale pixels on a real scanout were not observed directly.
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

## Session window behaviour (Lua config, not the plugin)

`config/hypr/grassfield/stacking.lua` and `placement.lua`; nested scenarios `tests/compositor/window_stacking.sh` and
`tests/compositor/window_placement.sh`.

- Stacking: a window that becomes active is raised (`alter_zorder top`) unless it is not floating, full-screen, or on a
  workspace that shows a full-screen window. Hyprland 0.56 already raises a floating window on a pointer press that
  changes focus (measured: press on the back window's visible part raises it, with and without the plugin), but not when
  focus arrives without a press (switcher, Dock, `focus` dispatcher, a program asking for focus): that window stayed behind
  the other one while being active, and a later press did nothing (no focus change, so no raise). The hook covers it.
- Placement: a browser window (class list in `placement.lua`) that opens smaller than 72 % x 82 % of the monitor's usable
  area (output minus the menu bar and Dock) is grown to that size; larger sizes are kept, and the window is centred by
  Hyprland.
- **Known limit:** other applications' first windows keep the size they ask for (terminal, Grassfield apps, dialogs,
  panels). Lua cannot tell a dialog, a popup or a utility panel from a main window (no parent or modal field on
  `HL.Window`), so a minimum size for every first window would also enlarge those. Widening the rule needs that signal
  (plugin, or an app class list).
