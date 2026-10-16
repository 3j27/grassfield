# ADR-0001: Grassfield session layout
Status: Proposed (applied provisionally per owner instruction of 2026-10-17) · Date: 2026-10-17 · Decider: owner

## Context
Grassfield Desktop is an add-on session on an unmodified Omarchy 4 (D1). Omarchy's Hyprland config
(`~/.config/hypr/hyprland.lua`) bootstraps `/usr/share/omarchy/default/hypr/*` and autostarts
`omarchy-shell`, Omarchy menus and Omarchy bindings. Grassfield needs its own shell (D2), bindings and
look, while keeping Omarchy's hardware setup (keyboard layout, monitors, NVIDIA env) and base services.

Verified (2026-10-17):
- Hyprland 0.56.2 config is Lua; `Hyprland --config FILE` selects the config; `--verify-config` validates it
  and reports unknown keys and rule fields (tested with a deliberately bad config).
- Nested Hyprland runs inside the owner's session: backend `wayland`, libseat fails to take the seat
  (expected, harmless), output `WAYLAND-1` sized by the parent's layout (941x508 observed, not the requested
  1440x900). A headless output created by the nested instance (`hyprctl output create headless GF-REF`,
  run as a child of the nested compositor) gives a deterministic 1920x1080 capture with `grim -o GF-REF`.
- Omarchy user hardware config lives in `~/.config/hypr/{monitors,input}.lua`; Omarchy env defaults in
  `/usr/share/omarchy/default/hypr/envs.lua` (also handles NVIDIA via `default.hypr.nvidia`).

## Options
1. **Separate Grassfield config that includes a small, version-checked subset of Omarchy** — own looks,
   bindings, autostart; reuse Omarchy envs and the user's monitors/input files read-only.
   Pros: Omarchy updates keep working; hardware config shared. Cons: depends on Omarchy module names.
2. Fully standalone config (copy Omarchy envs). Pros: no coupling. Cons: duplicates hardware logic, drifts.
3. Layer on top of the user's Omarchy config and unbind/override. Cons: Omarchy autostarts omarchy-shell
   and its bindings; fragile; violates D2.

## Decision
Option 1.
- Real session: `config/hypr/session.lua` (installed to `/usr/share/grassfield/hypr/`). It sets `package.path`
  to Grassfield's config dir, then `require("grassfield.omarchy")`, a guarded include that checks
  `/usr/share/omarchy` and the Omarchy version and loads only: `default.hypr.envs` and the user's
  `hypr.monitors`, `hypr.input` (read-only, never written). If the include fails, Grassfield defaults apply
  and the shell shows one notification. Then `require("grassfield.core")`.
- Dev session: `config/hypr/dev.lua`, started only by `scripts/dev/nested-up.sh` (refuses to run without
  `GRASSFIELD_CONFIG_DIR`). No Omarchy include, no owner dotfiles. State in `.dev/`.
- Session entry (M2, owner installs): `/usr/share/wayland-sessions/grassfield.desktop` →
  `uwsm start -e -D Grassfield -- Hyprland --config /usr/share/grassfield/hypr/session.lua`. The Omarchy
  session stays the fallback in SDDM.
- Graphical recipes run outside the Claude Code sandbox via `sandbox.excludedCommands` and still ask.

## Evidence
`Hyprland --verify-config` exit 0 on `config/hypr/dev.lua`; S0 nested run and `.dev/shots/s0-ref.png`
(1920x1080) on 2026-10-17.

## Consequences
- Omarchy module renames break the include → caught by the version check and C2-like fallback.
- `XDG_CURRENT_DESKTOP=Hyprland` is kept (portals); Grassfield sets `XDG_SESSION_DESKTOP=Grassfield`.
- Revisit if Omarchy exposes a stable "hardware only" include.
