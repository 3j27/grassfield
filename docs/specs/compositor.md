# grassfield-compositor spec · compositor-engineer · M0 spike S2 → M1 decorations

Status: S2 slice implemented (titlebars + gfc/1 capabilities). Code: `compositor/`. Build and run: `compositor/README.md`.

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)

- Every standard window has a titlebar strip about 28 pt tall that is part of the window: same corner
  radius as the window at the top, square joint with the content, one continuous outline and shadow.
- Three circular buttons on the left, 12 pt diameter, evenly spaced (8 pt gaps), vertically centered:
  close, minimize, zoom. Glyphs appear on hover; inactive windows show grey buttons.
- The window title is centered on the full titlebar width in semibold system text, never overlapping the
  buttons, truncated with an ellipsis when too long.
- Dragging the titlebar moves the window; double-clicking it performs the user's chosen action (default: zoom).
- Buttons act on mouse-up over the same button (press, move away, release = cancel).

## Purpose and non-goals

Purpose (S2): prove that a Hyprland 0.56.2 plugin built against the installed headers can draw and drive
macOS-like titlebars on floating windows, and that the shell can discover the plugin's capabilities over
IPC under Hyprland's Lua config (input for ADR-0007).

Non-goals in S2: real minimize (M2), hover glyphs and inactive-state buttons, appearance switching,
per-Settings double-click action, tiled windows, CSD negotiation, appmenu protocol, overview transforms.

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
  `minimize-request` only (**placeholder**, M2).
- **FR7** A left press elsewhere on the bar focuses and raises the window (without warping the cursor) and
  starts an interactive move that follows the pointer from the press point; release ends it. The move (and
  an armed button, FR6) also ends, where it is, on any new press, and on a pointer motion when Hyprland
  reports no held button or a pointer device present at the press has disappeared: a lost release never
  leaves the window following the pointer.
- **FR8** Two presses on the drag area within 400 ms and 4 px toggle maximized (no move).
- **FR9** At load and on `hl.plugin.grassfield.hello()` the plugin posts the socket2 event
  `grassfield>>{"v":"gfc/1","type":"capabilities","features":["decorations"]}`.
- **FR10** `hyprctl grassfield` returns the same capabilities JSON.
- **FR11** No exception escapes into Hyprland; window/monitor pointers are null-checked; no blocking I/O.
- **FR12** `PLUGIN_EXIT` removes all titlebars, Lua functions, the hyprctl command and event listeners,
  and ends a drag in progress. Titlebars of unmapped or hidden windows are destroyed too (Hyprland defers
  their removal), and no pointer to a destroyed titlebar stays in Hyprland's plugin bookkeeping.
- **FR13** Press ownership: a release is kept from clients if and only if a titlebar consumed the matching
  press (per button; a new press of a button supersedes an older one). Such a release is consumed by the
  titlebar when Hyprland routes it there, otherwise cancelled on the event bus; releases of presses that
  went to clients are never touched.

## Acceptance criteria (each mapped to a test or scenario; level L0/L1/L2)

| FR | Test / scenario | Level | S2 result |
|---|---|---|---|
| FR1 | Code review of `PLUGIN_INIT`; scripted mismatch test (C2) | L0 / L1 | match path verified (log); mismatch path NOT VERIFIED |
| FR2 | nested: open foot → screenshot | L1 | verified (floating); tiled/full-screen hiding NOT VERIFIED |
| FR3 | nested screenshot, corner crops | L1 | verified at scale 1 (see limitations) |
| FR4 | unit `TitlebarLayout.*`, `Theme.*`; screenshot | L0 / L1 | verified |
| FR5 | unit `TitlebarLayout.Title*`; screenshot with long and short titles | L0 / L1 | verified |
| FR6 | nested: virtual pointer clicks on close / zoom / minimize; press on close + release elsewhere | L1 | verified (close closed the window; zoom toggled `fullscreen` 0↔1; minimize posted `minimize-request`; cancel kept the window) |
| FR7 | nested: virtual pointer drag, window position before/after; abandoned drag (pointer tool exits after `down drag`, its device is destroyed) then move and click elsewhere with a new pointer | L1 | verified: press (500,186) → release (600,286) moved the window (370,200) → (470,300), cursor not warped. Abandoned drag (2026-10-17): before the fix the window followed the unpressed pointer and jumped to the next click; after it the window stays where the drag left it, the next click lands on the desktop, log `titlebar gesture cancelled: no button held or a pointer device went away` |
| FR8 | unit `ClickTracker.*`; nested double-click | L0 / L1 | verified: `fullscreen` 0 → 1, titlebar kept on the maximized window |
| FR9 | spike `spikes/s2-ipc/shell.qml` (Quickshell `rawEvent`) | L1 | verified for `hello`; load-time event not observable |
| FR10 | `hyprctl grassfield` against the nested instance | L1 | verified |
| FR11 | code review; `clang-tidy` (Q1); C1 soak `tests/compositor/soak.sh` | L0 / L1 | see "Performance (gates affected)" |
| FR12 | `just plugin-unload` (needs `scripts/nestctl`); nested shutdown (SIGTERM → `CCompositor::cleanup` → `unloadAllPlugins` → `PLUGIN_EXIT`, then dlclose, then windows destroyed) with windows on `special:hidden` | L1 | runtime `hyprctl plugin unload` NOT VERIFIED (no `scripts/nestctl`); shutdown with 2 windows on `special:hidden`: log `[grassfield] grassfield-compositor unloaded`, `Hyprland has reached the end.`, no core dump. Hidden (`isHidden()`) / unmapped-window path: code inspection only |
| FR13 | unit `PointerGesture.*`; nested: double-click zoom, zoom-button press moved away, drag-select in another window after a titlebar click or drag | L0 / L1 | verified: no seat warning during these scenarios, the cancelled zoom press changed nothing, the other window received its selection drag. Releases cancelled on the bus leave a stale held button in Hyprland (Known limitations) |

## Interfaces / contracts (versions)

`gfc/1` (master-prompt §5.3). Measured transport in S2:

| Direction | Mechanism | Payload |
|---|---|---|
| plugin → shell | Hyprland socket2 event `grassfield` | `{"v":"gfc/1","type":"capabilities","features":["decorations"]}` |
| plugin → shell | socket2 event `grassfield` (minimize button, placeholder) | `{"v":"gfc/1","type":"minimize-request","address":"<hex, no 0x>"}` |
| shell → plugin | Lua function `hl.plugin.grassfield.hello()` via `Hyprland.dispatch("hl.plugin.grassfield.hello()")` | re-posts capabilities |
| query | `hyprctl grassfield` | capabilities JSON |

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

Future verbs (minimize, restore, …) follow the same pattern: `hl.plugin.grassfield.<verb>(args)`, results as
`grassfield` socket2 events.

## Dependencies (verified versions)

- Hyprland 0.56.2 (commit `efb50993780079460b0cbed1363e2166a2de1d9f`), headers in `/usr/include/hyprland`.
- APIs used (all read from the 0.56.2 headers): `HyprlandAPI::{addWindowDecoration, removeWindowDecoration,
  addLuaFunction, removeLuaFunction, registerHyprCtlCommand, unregisterHyprCtlCommand, addNotification,
  getHyprlandVersion}`, `Event::bus()->m_events.{window.open, window.floating, window.fullscreen,
  window.title, window.updateRules, input.mouse.button}` (the deprecated `registerCallbackDynamic` is not
  used), `g_pEventManager->postEvent`, `IHyprWindowDecoration`, `g_pDecorationPositioner`,
  `g_pHyprRenderer->addPassElement` with `CRectPassElement` / `CTexPassElement`, `renderText`,
  `g_layoutManager->setTargetGeom` (move), `Desktop::focusState()->fullWindowFocus`,
  `Fullscreen::controller()->setFullscreenMode`, `Config::Actions::{closeWindow, alterZOrder}`,
  `Event::bus()->m_events.input.mouse.move`, `g_pInputManager->{hasHeldButtons(), m_pointers,
  getMouseCoordsInternal()}`, `Desktop::viewState()->hitTest().windowAt`, `CWindow::{hasPopupAt,
  m_windowDecorations, m_decosToRemove}`, `g_pDecorationPositioner->{uncacheDecoration, forceRecalcFor}`,
  `g_pPluginSystem->getPluginByHandle()->m_registeredDecorations`.
- Behavior read from the installed 0.56.2 binary (`objdump -d` of the exported symbols; member offsets
  checked with `static_assert(offsetof(...))` against the headers), relied on by FR7, FR12, FR13:
  - `CWindow::updateWindowDecos()` returns at once when `!m_isMapped` or `isHidden()`, so a removal queued by
    `removeWindowDecoration` → `CWindow::removeWindowDeco` (push to `m_decosToRemove`) waits for the window
    to be mapped and visible again.
  - `CPluginSystem::unloadPlugin(plugin, false)` calls `pluginExit` first, then `removeWindowDecoration()` for
    every pointer in a copy of `CPlugin::m_registeredDecorations` (never pruned by Hyprland), then `dlclose`.
    `CCompositor::cleanup()` (normal exit) unloads every plugin this way.
  - `CInputManager::onMouseButton` emits `input.mouse.button` first; a cancelled event returns before
    `m_currentlyHeldButtons` is updated. Releases of buttons not in that list are dropped. Button events
    then go to `CKeybindManager::onMouseEvent`, the decorations of `windowAt(pos, RESERVED_EXTENTS |
    INPUT_EXTENTS | ALLOW_FLOATING)` through `CWindow::checkInputOnDecos` (box contains point, no popup there),
    and finally `CSeatManager::sendPointerButton`.
  - `CWLPointerResource::sendButton` logs `sendButton release on a non-pressed button` and sends nothing
    when the client never got the press.
  - `CInputManager::destroyPointer` does not release the buttons held by the removed device.
- Measured pitfalls: `Config::Actions::focus()` warps the cursor to the window middle when the pointer is
  on the titlebar (outside the client surface); with it, drags through `CLayoutManager::beginDragTarget` or
  `CKeybindManager::changeMouseBindMode` jumped by (middle − press point). The plugin now focuses through
  `focusState()` and moves the window itself (no snapping); Hyprland's drag path should be re-tested in M1.
- The decoration priority must be above the border's (10005 used): at 10000 the titlebar was placed
  outside the border.
- GCC 16.2.1, C++23. Lua 5.5 headers (Hyprland links `liblua.so.5.5`). GoogleTest 1.18.0 for tests.
- Quickshell 0.3.1 for the IPC spike.

## Degraded behavior (plugin missing, service missing)

- ABI mismatch: no hooks, one notification, no `grassfield` event, `hyprctl grassfield` unknown → the
  shell sees no capabilities and keeps client-side decorations (§5.6).
- Init failure: everything registered so far is torn down, one notification, same fallback.
- Minimize: the button only reports `minimize-request`; the shell may emulate minimize (special
  workspace) in M2. `minimize` is not advertised.

## Automated tests · Manual verification steps

Automated (L0): `compositor/build/grassfield-compositor-tests` — protocol JSON (wire format, escaping,
advertised features), button layout, hit-testing, title placement, double-click detection, theme values,
pointer press ownership and gesture end (`PointerGesture.*`). Lint (Q1): `compositor/build-direct.sh tidy`
(`compositor/.clang-tidy`). Soak (C1): `tests/compositor/soak.sh [seconds]` (see `compositor/README.md`).

Manual (L1, nested only):

1. Build: `compositor/build-direct.sh`.
2. Start: `scripts/dev/nested-up.sh` (`config/hypr/dev.lua` loads `GRASSFIELD_PLUGIN` at parse time; a load
   from a `hyprland.start` callback would be ignored because Hyprland applies the config's plugin list right
   after parsing; fixed in commit eaa953c, the S2 shim is gone).
3. Log (`$XDG_RUNTIME_DIR/hypr/<nested instance>/hyprland.log`):
   `[grassfield] grassfield-compositor 0.1.0-s2 initialised on Hyprland v0.56.2 (commit …), ABI hash match`.
4. `WAYLAND_DISPLAY=$(cat .dev/nested.wayland) setsid foot >/dev/null 2>&1 &`, then
   `scripts/dev/shot.sh titlebar GF-REF`.
5. IPC: `WAYLAND_DISPLAY=… HYPRLAND_INSTANCE_SIGNATURE=… timeout 10 qs -p spikes/s2-ipc/shell.qml`.
6. Pointer (`tests/tools/vpointer`, coordinates relative to an output): e.g.
   `scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 700 400 up`. Abandoned drag (FR7):
   `scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 800 350` (no `up`), then
   `scripts/dev/pointer.sh output GF-REF abs 1400 700 sleep 200 abs 300 300 click`: the window must not move.

## Performance (gates affected) · Accessibility · i18n

- C1: soak script `tests/compositor/soak.sh` (nested only). 2026-10-17, plugin at commit a475092:
  `tests/compositor/soak.sh 1260` → PASS (1260 s, 758 rounds: 758 short-lived + 758 churn windows,
  217 drags, 109 abandoned drags, 216 zoom pairs, 108 cancelled and 108 real close clicks; 1197 titlebar
  presses; nested Hyprland alive, RSS 151.7 → 158.5 MB, no core dump, 0 grassfield exceptions, clean unload
  at shutdown). 9 seat warnings `sendButton release on a non-pressed button` came from Hyprland releasing
  stale held buttons at window map/unmap (see Known limitations); the seat drops them. The 1 h and 8 h runs
  are scheduled: C1 stays NOT VERIFIED until the 8 h run passes. C2 (scripted degradation) not run.
  Title textures are cached per window and rebuilt only when the title, scale or available width changes;
  drawing adds 6 rect pass elements and 1 texture per decorated window.
- Q1: `compositor/build-direct.sh tidy` must exit 0 with no diagnostics.
- Accessibility: titlebar buttons are compositor-drawn and not exposed to assistive technologies; keyboard
  equivalents exist (SUPER+W close, SUPER+ALT+F zoom).
- i18n: no plugin strings are shown except the degradation notifications (English, compositor-side).

## Known limitations (honest, user-visible gaps vs macOS)

- Minimize does nothing visible (placeholder; M2).
- No hover glyphs (×, −, +), no grey inactive-window buttons, no pressed state.
- Appearance is fixed to dark; light colors exist in `Theme.hpp` but are not switchable yet.
- Double-click always zooms (no Settings choice yet).
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
- When a titlebar release has to be cancelled on the event bus (pointer no longer over a titlebar: a
  button press moved away, a double-click zoom, and in practice every drag, because the bar lags the
  pointer while the window's move animation runs), Hyprland's held-button list keeps that button until its
  next release (no public API to clear it). When a window maps or unmaps meanwhile, Hyprland's
  `releaseAllMouseButtons` sends that stale release to the focused client, and the seat drops it with the
  warning `sendButton release on a non-pressed button`. Input to the next window clicked was correct in
  the nested test (drag-select after a titlebar drag). Hyprland itself never releases the buttons of a
  removed pointer device.
