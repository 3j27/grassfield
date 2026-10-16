# ADR-0007: Shell ↔ plugin IPC (`gfc/1`)
Status: Proposed — pending spike S2 evidence · Date: 2026-10-17 · Decider: owner

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
Option 1, versioned `gfc/1`:
- Handshake: at startup the shell dispatches `grassfield:hello gfc/1`; the plugin answers (and also emits at
  load) `grassfield>>{"v":"gfc/1","type":"capabilities","features":[...]}`. No reply within 1500 ms →
  degraded mode (§5.6) and one notification.
- Shell → plugin verbs: `grassfield:minimize <address> <x> <y> <w> <h>`, `grassfield:restore <address>`,
  `grassfield:overview <on|off>`, `grassfield:dock-rects <json>`; arguments are space-separated or one
  compact JSON object; the plugin validates everything (untrusted input).
- Plugin → shell events: `capabilities`, `minimized`, `restored`, `appmenu` (address → service, path),
  `button` (titlebar actions needing the shell). Payloads never contain window contents or secrets.
- Unknown `v` major → the shell treats the plugin as absent.

## Evidence
To be filled from S2: whether `Hyprland.dispatch` reaches plugin dispatchers when Hyprland runs a Lua
config, and the event API used.

## Consequences
- Breaking payload changes bump `gfc/N` and need a new ADR.
- If S2 shows dispatch does not reach plugin dispatchers under Lua, fall back to `addLuaFunction` +
  `hyprctl eval` from the shell platform layer (one-shot process per action, no polling) or option 2.
