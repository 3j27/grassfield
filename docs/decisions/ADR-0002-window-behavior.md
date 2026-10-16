# ADR-0002: Window behavior
Status: Proposed (applied provisionally) · Date: 2026-10-17 · Decider: owner

## Context
macOS windows are floating, have titlebars with close/minimize/zoom on the left, minimize into the Dock,
and are focused by click while scrolling follows the pointer. Hyprland 0.56.2 is a tiling compositor
with no server-side titlebars (it answers SERVER_SIDE to xdg-decoration but draws nothing) and no
minimized state (master-prompt §2). D3 puts titlebars and minimize in `grassfield-compositor`.

## Options
1. Floating-first via a catch-all `float = true` window rule; tiling remains available per window.
2. A custom floating algorithm (`HyprlandAPI::addFloatingAlgo`) in the plugin. More control, more risk; not needed for M1.
3. Keep dwindle tiling with a "floating mode" toggle. Not macOS-like.

## Decision
Option 1 for M1, revisit option 2 when Stages (M5) needs placement control.
- **Placement**: new windows float at the client's preferred size, centered on the focused monitor.
- **Focus**: `input.follow_mouse = 2` (keyboard focus on click, pointer focus follows hover, so scrolling
  works on background windows), `float_switch_override_focus = 0`.
- **Titlebars**: drawn by the plugin for windows using server-side decorations; 28 px; buttons on the left
  in the order close, minimize, zoom; title centered; drag to move; double-click action from Settings
  (default: zoom). GTK/libadwaita CSD windows keep their own header bars; Grassfield sets
  `gtk-decoration-layout=close,minimize,maximize:` in its session so their buttons are on the left (§4).
- **Close** = close the window (`window.close`). Apps keep their own quit semantics.
- **Zoom** (green button) = toggle Hyprland `fullscreen` mode `maximized` (fills the work area, menu bar and
  Dock stay). Option+click → true full screen. This follows the current macOS default (green button =
  full screen) only partially: true full-screen Spaces are deferred, documented as a known limitation.
- **Minimize**: plugin hidden state + genie-like scale animation toward the Dock icon rectangle sent by the
  shell (M2). Fallback without plugin: move to a special workspace `special:minimized`, restore from Dock.
- **Keyboard**: SUPER plays Command for desktop actions (`SUPER+Q/W` close, `SUPER+SPACE` Search,
  `CTRL+UP` Overview, `CTRL+LEFT/RIGHT` Spaces). App shortcuts stay on Ctrl (no global Cmd→Ctrl remap in 1.0).
- **Rounding**: fixed 12 px radius, `rounding_power = 2.6` (continuous-corner approximation), hairline border.

## Evidence
`config/hypr/grassfield/{windows,input,bindings,looknfeel}.lua` pass `Hyprland --verify-config` (2026-10-17).

## Consequences
- Some tiling users lose their habits in the Grassfield session (Omarchy session unchanged).
- Cmd-style app shortcuts (Cmd+C) are not remapped; known limitation, possible post-1.0 ADR.
- The plugin must not decorate CSD windows twice; it decorates only windows without client decorations.
