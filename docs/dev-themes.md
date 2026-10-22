# Dev-only icon and cursor themes (ADR-0014)

Nothing here touches the owner's system: every theme lives under `.dev/share/icons` (git-ignored), and
`~/.local/share/icons`, `~/.icons` and `/usr` are never written.

## App icons (ADR-0017, amended 2026-10-21)

- Dev sessions use the same chain as the real one: the wrapper theme `grassfield-icons` (Grassfield's own icons, then
  Breeze, Adwaita and hicolor, all installed with Omarchy). Nothing is fetched or provisioned: the WhiteSur theme and
  `scripts/dev/whitesur.sh` are gone.
- `scripts/dev/devenv.sh` (sourced by `nested-up.sh`, `shell-run.sh` and `isolated.sh`) puts `.dev/share` first in
  `XDG_DATA_DIRS`, installs the wrapper theme (`branding/icons/theme/index.theme`) into `.dev/share/icons` and always sets
  `QT_QPA_SYSTEM_ICON_THEME=grassfield-icons`, which Qt reads for the shell (Quickshell) and the Grassfield apps.
  ADR-0017 replaces the earlier plan (`QT_ICON_THEME`, the Quickshell
  pragma); the real session sets the same variable through `/usr/share/uwsm/env-grassfield`.
- Limit: Grassfield's own UI glyphs (`branding/icons/symbolic`) are not theme icons; only app and file icons (Dock,
  Apps, Search) follow the theme. They also follow the icon appearance mode (`icons.mode`: default, dark, clear, tinted; docs/specs/ui.md), which is applied by the renderer and works on any theme.

## Grassfield cursors

- `just cursors` (or `branding/cursors/build.sh`) builds `.dev/share/icons/grassfield-cursors` (hyprcursor SVG theme
  and XCursor fallback, about 10 s on 8 cores). Options: `--name`, `--fill`, `--outline`, `--sizes`, `--out`.
- The nested Hyprland picks it up through `config/hypr/grassfield/cursor.lua` (HYPRCURSOR_* and XCURSOR_* through
  `hl.env`) when the folder exists. Change theme or size in the nested instance only: `scripts/nestctl setcursor
  <theme> <size>`; the pointer must leave and re-enter a surface before the new cursor shows.
