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
- Verbs (planned): `hello()`, `minimize(address, x, y, w, h)`, `restore(address)`, `overview(on)`,
  `theme(json)`; events: `capabilities`, `minimize-request`, `minimized`, `restored`, `appmenu`.
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
