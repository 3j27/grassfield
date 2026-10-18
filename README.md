# Grassfield

A polished, familiar desktop experience for Omarchy 4, delivered as **Grassfield Desktop**: an add-on Hyprland
session installed on top of an unmodified Omarchy system ("built for Omarchy", "based on Arch Linux").
**Grassfield OS** (ISO and installer) comes after the desktop beta.

Status: pre-alpha, private repository. Current state and verified facts: [`docs/STATE.md`](docs/STATE.md).
Project brief: [`docs/master-prompt.md`](docs/master-prompt.md). Decisions: [`docs/decisions/`](docs/decisions/).

## Components

| Path | What |
|---|---|
| `config/hypr/` | Grassfield Hyprland session (Lua): `session.lua` (real session), `dev.lua` (nested dev session) |
| `shell/` | `grassfield-shell`, a standalone Quickshell instance: menu bar, Dock, Overview, Search, Control Center, notifications, lock, polkit, idle |
| `ui/` | `Grassfield.Ui` QML design system: tokens, material, components |
| `compositor/` | `grassfield-compositor`, optional C++ Hyprland plugin: titlebars, minimize, appmenu protocol, overview transforms |
| `branding/` | Grassfield's own icons and artwork (see `branding/LICENSES.md`) |

## Development (nested only)

Requirements: Omarchy 4 with Hyprland 0.56.x, Quickshell 0.3.x, Qt 6.11, plus `cmake ninja just qt6-tools`.

```bash
just check          # Lua config validation, qmllint, script syntax
just test           # offscreen unit tests
just nested-up      # nested Hyprland + grassfield-shell, state in .dev/
just shot NAME      # screenshot of the 1920x1080 reference output → .dev/shots/NAME.png
just nested-down
```

Never run the shell or the plugin against your real session while developing; see `docs/master-prompt.md` §7.

## Legal

Not affiliated with Apple, Arch Linux or Omarchy. No Apple assets are used. License: pending ADR-0005.
