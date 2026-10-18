# ADR-0007: Shell ↔ plugin IPC (`gfc/1`)
Status: Proposed (S2 evidence recorded; applied provisionally) · Date: 2026-10-17 · Decider: owner

## Context
grassfield-shell (Quickshell) must drive `grassfield-compositor` (minimize with target rectangles,
overview transforms, appmenu registrations, capability detection) and receive its events. Constraints:
§5.4 never poll `hyprctl`, never leave IPC sockets open; the shell must work without the plugin (§5.6).
Quickshell 0.3.1 `Quickshell.Hyprland` exposes `Hyprland.dispatch(request)` (Hyprland request socket) and
`Hyprland.rawEvent(event)` (socket2 event stream it already holds open), and a `usingLua` property.
Hyprland 0.56.2 plugin API offers `addDispatcherV2`, `registerHyprCtlCommand`, `addLuaFunction`,
`addEvent` (Lua `hl.on`), and the socket2 event manager.

## Options
1. **Hyprland's own IPC**: shell → plugin through plugin dispatchers (`grassfield:<verb> <args>`);
   plugin → shell through socket2 events (`grassfield>>{json}`); diagnostics via `hyprctl grassfield`.
   Pros: no new socket, reuses connections Quickshell already manages, works under the nested guard rails.
   Cons: dispatcher arguments are a single string; events are broadcast to every socket2 client (no secrets).
2. Plugin-owned Unix socket with JSON lines. Pros: request/response, private. Cons: a second socket to
   secure and version; blocking risks on the compositor thread; more code.
3. D-Bus service inside the compositor process. Cons: event-loop integration in Hyprland, heavier.

## Decision (proposed)
Option 1 adapted to the Lua config, versioned `gfc/1`:
- **Shell → plugin: Lua functions**, registered by the plugin with `HyprlandAPI::addLuaFunction(handle,
  "grassfield", "<verb>", fn)` and reachable as `hl.plugin.grassfield.<verb>(...)`. The shell's platform layer
  sends them through `Hyprland.dispatch(<Lua function body>)` (Quickshell wraps requests as
  `return hl.dispatch(<request>)` when `usingLua` is true), guarded by
  `local p = hl.plugin and hl.plugin.grassfield; if p and p.<verb> then ... end` so a missing plugin is a no-op.
  Each function returns `hl.dsp.no_op()` so the wrapping dispatch does not error.
- **Plugin → shell: socket2 events** `grassfield>>{json}` (`g_pEventManager->postEvent`), received by
  `Hyprland.rawEvent` in `shell/platform/`.
- **Diagnostics**: `hyprctl grassfield` (read-only JSON, same as the capabilities event).
- Handshake: the shell calls `hl.plugin.grassfield.hello()` at startup; the plugin answers (and emits at load)
  `{"v":"gfc/1","type":"capabilities","features":[...]}`. No reply within 1500 ms → degraded mode (§5.6).
- Verbs implemented (2026-10-17): `hello()`, `minimize(address, x, y, w, h)`, `restore(address, x, y, w, h)`
  (target rect = the Dock tile in layout coordinates), `config(key, value)` (allowlist: `titlebarDoubleClick` ∈
  zoom|minimize|none), `appmenu(address)` (re-posts that window's registration), `overview(json)` (2026-10-18,
  additive: one JSON string `{"on":bool,"durationMs":int,"curve":[x1,y1,x2,y2]?,"windows":[{"address","x","y","w","h"}…]}`
  in layout coordinates, at most 64 windows and 16 KiB, validated strictly by the plugin; live window transforms for
  Mission Control v2, contract in `docs/specs/overview.md` "Shell contract"). Planned: `theme(json)`. Events:
  `capabilities` (features: `decorations`, `minimize`, `config`, `appmenu`, `overview`, `desktop-focus`), `minimize-request`,
  `minimized`, `restored`, `appmenu` `{address, service, path, pid}` (additive field `pid` = the Wayland client's pid
  from `wl_client_get_credentials`; the menu bridge checks it against `GetConnectionUnixProcessID(service)` to stop one
  app pointing its window at another app's menu), `overview` `{state: opening|open|closing|closed, windows, reason?}`
  (`reason`: `invalid` / `no-windows` / `no-chrome` for a refused request, which changes nothing; `unavailable` at unload;
  `interrupted` when the overview ended without the shell's request; `fullscreen` when a window went full screen while
  shown and its workspace's windows left the overview, the state otherwise unchanged).
- Feature `desktop-focus` (2026-10-18, additive, no verb): the plugin enforces click-to-focus for the shell's desktop
  surface (namespace `grassfield-desktop-icons`) on pointer presses (ADR-0012 amendment); contract in
  `docs/specs/desktop.md` "Compositor focus policy". Advertised only when its listeners registered.
- Withdrawal at unload (2026-10-18, additive): `PLUGIN_EXIT` posts `{"v":"gfc/1","type":"capabilities","features":[]}`
  after removing every hook, so the shell drops each feature and returns to its fallbacks (desktop focus workarounds,
  minimize parking, T0 menus, thumbnails). The shell must treat every capabilities event as the current truth.
- Delivery (2026-10-17, after the global menus review: an unbounded `appmenu` stream overflowed the shell's socket2
  connection and Hyprland dropped it): every plugin → shell event goes through `compositor/src/core/EventThrottle`,
  keyed by window (`minimized`/`restored` share one key, as do an appmenu clear and set), latest value wins, at most
  one post per key per 100 ms with an event-loop timer posting the final state after a burst; global cap 32 events
  burst, then 50/s; `overview` has one key of its own (the latest state wins). Events are coalesced, never required one by one: the shell rebuilds minimize state from
  `movewindowv2` and can ask for a window's registration again with `appmenu(address)`. Client-triggerable log lines
  share one budget, titlebar pointer actions included.
- The shell only calls verbs listed in `shell/platform/Minimized.js` `isPluginVerb`.
- All arguments are validated by the plugin (untrusted). Payloads never carry window contents.
- Unknown `v` major → the shell treats the plugin as absent.

## Evidence
Spike S2 (2026-10-17, nested Hyprland 0.56.2, Quickshell 0.3.1):
- `Hyprland.dispatch("grassfield:hello")` with an `addDispatcherV2` dispatcher FAILS under the Lua config:
  Quickshell sends `return hl.dispatch(grassfield:hello)` → Lua error "function arguments expected".
- `hl.plugin.grassfield.hello()` registered with `addLuaFunction` WORKS; Quickshell received
  `rawEvent grassfield>>{"v":"gfc/1","type":"capabilities","features":["decorations"]}`.
- `hyprctl grassfield` returns the capabilities JSON.

## Consequences
- Breaking payload changes bump `gfc/N` and need a new ADR.
- Depends on Quickshell keeping the `usingLua` dispatch wrapping; re-verify on every Quickshell minor update.
