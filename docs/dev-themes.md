# Dev-only icon and cursor themes (ADR-0014)

Nothing here touches the owner's system: every theme lives under `.dev/share/icons` (git-ignored), and
`~/.local/share/icons`, `~/.icons` and `/usr` are never written.

## WhiteSur icons (third party, GPL-3.0)

- `scripts/dev/whitesur.sh` fetches vinceliuice/WhiteSur-icon-theme at a pinned commit (GitHub only, one `git fetch`),
  verifies the commit and the SHA-256 of its reviewed `install.sh`, and installs `WhiteSur`, `WhiteSur-light` and
  `WhiteSur-dark` into `.dev/share/icons`, with `COPYING` and `AUTHORS` next to each. Idempotent (`--force` reinstalls).
  `just whitesur` runs it. Nothing from the theme is committed to this repository.
- `scripts/dev/nested-up.sh` runs it once when the theme is missing; a failure (offline) only prints a warning.
- `scripts/dev/devenv.sh` (sourced by `nested-up.sh`, `shell-run.sh` and `isolated.sh`) puts `.dev/share` first in
  `XDG_DATA_DIRS` and, when WhiteSur is installed, sets `QT_QPA_SYSTEM_ICON_THEME=WhiteSur`, which Qt reads for the
  shell (Quickshell) and for the Grassfield apps. Without the theme nothing changes (hicolor and the system theme stay
  as the fallback chain).
- Limit: Grassfield's own UI glyphs (`branding/icons/symbolic`) are not theme icons; only app and file icons (Dock,
  Apps, Search) follow the theme.

## Grassfield cursors

- `just cursors` (or `branding/cursors/build.sh`) builds `.dev/share/icons/grassfield-cursors` (hyprcursor SVG theme
  and XCursor fallback, about 10 s on 8 cores). Options: `--name`, `--fill`, `--outline`, `--sizes`, `--out`.
- The nested Hyprland picks it up through `config/hypr/grassfield/cursor.lua` (HYPRCURSOR_* and XCURSOR_* through
  `hl.env`) when the folder exists. Change theme or size in the nested instance only: `scripts/nestctl setcursor
  <theme> <size>`; the pointer must leave and re-enter a surface before the new cursor shows.
