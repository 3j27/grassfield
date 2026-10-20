# ADR-0014: Icon appearance modes with live tint, and Grassfield's own cursor set
Status: Proposed (owner request 2026-10-19; applied provisionally) · Date: 2026-10-19 · Decider: owner
See ADR-0017 for the WhiteSur distribution, the session theme selection and the Apple-logo guard (it supersedes the "pragma / QT_ICON_THEME" plan here).

## Context
The owner wants icons and cursors as Grassfield capabilities: icons with a live tint like the macOS 26 icon appearance
modes (Default, Dark, Clear, Tinted) and Material You themed icons, and Grassfield's own cursor set with an adjustable
accent and size. Owner decisions (2026-10-19, docs/STATE.md):
- Base icon theme for the internal phase: WhiteSur (third-party, GPL-3.0, a macOS-style theme), shipped as a package
  dependency and never vendored into this MIT repository; a designer replaces it with Grassfield's own set in 6–8 months.
  Apple's own icons are never used (hard rule). docs/legal/visual-review.md E27 must be reviewed again before any
  public release.
- Cursors: drawn by Grassfield now (vector), accent and size adjustable.

Facts (research 2026-10-19, read-only):
- Quickshell 0.3.1 `IconImage` is a thin wrapper over a QtQuick `Image` and exposes it (`backer`), and
  `Quickshell.iconPath` resolves theme icons (`/usr/lib/qt6/qml/Quickshell/Widgets/IconImage.qml`, quickshell-core.qmltypes).
  Qt 6.11 ships `MultiEffect` (colorization, saturation, brightness, contrast) and `qsb` (`/usr/lib/qt6/bin/qsb`) for
  custom shaders.
- Third-party icons have no separate glyph layer (unlike Android's monochrome layer or Apple's per-mode layers): a tint
  on arbitrary icons is an approximation (luminance mapped to a two-tone ramp of the tint colour, alpha kept).
- hyprcursor 0.1.13: a theme is `manifest.hl` plus one folder per cursor (`meta.hl`: hotspot, overrides, sizes), PNG or
  SVG (SVG is size-independent), built with `hyprcursor-util --create`; Hyprland switches theme and size at runtime
  (`setcursor`); XWayland, GTK and Qt read XCursor themes (fallback needed). Adwaita lists ~35 CSS cursor names; legacy
  X11 aliases (left_ptr, hand2, xterm, watch, fleur, sb_h/v_double_arrow…) keep old toolkits working.

## Options
Icons:
1. **Live tint in the renderer:** one shared `TintedIcon` component (ui/Grassfield/Ui) used by every Grassfield surface
   that shows an app or file icon (Dock, Apps panel, Search, desktop, Files, Preview), applying the mode with a GPU effect.
   No files written; switching is instant.
2. Generate a tinted copy of the whole icon theme on disk (~10k files) on every change; every app sees it.
3. Both: 1 for Grassfield surfaces now, 2 later for third-party apps.

Cursors:
A. **Grassfield SVG sources → hyprcursor theme (SVG) + XCursor fallback built at package time; a custom accent or size
   regenerates the theme into the user's data directory and switches to it.**
B. A fixed palette of prebuilt accent variants only.

## Decision (proposed)
- **Icons: option 3, phased.** Phase 1 = option 1: `TintedIcon` with modes `default` (unchanged), `dark` (darker plate,
  luminance compressed, contrast kept), `clear` (desaturated, lighter, translucent over the material), `tinted`
  (luminance → two-tone ramp of the tint colour, alpha kept). First implementation with `MultiEffect`
  (colorization/saturation/brightness); a custom `qsb` shader only if MultiEffect cannot reach the look or the cost
  target. Effects are enabled only when the mode is not `default` (no offscreen pass by default); a per-surface layer is
  used instead of one pass per icon where many icons are shown (Apps panel, Files grid). Phase 2 (later, own review):
  a generated tinted theme for third-party apps, regenerated in the background.
- Settings keys (settings contract, versioned): `icons.mode` (`default|dark|clear|tinted`, default `default`),
  `icons.tint` (`accent` or `#rrggbb`, default `accent`). (Implemented 2026-10-19 under `icons.*` because `appearance` is
  already a string key in contract version 1.) Settings › Appearance gets the mode and tint controls (macOS 26
  layout). Folder colours (owner request 2026-10-19) are a separate step, `icons.folderColor` (`theme|accent|#rrggbb`, default `theme`) and a per-folder colour and symbol (docs/specs/ui.md, docs/specs/files.md), so the mode effects stay untouched. The shell and Grassfield apps react live.
- Base theme: Grassfield sets the icon theme name for its session and for the shell (Quickshell's IconTheme pragma or
  `QT_ICON_THEME`/environment, whichever the installed version supports — verify), with WhiteSur first and the
  freedesktop fallback chain (`hicolor`, then the system theme) for missing icons. Packaging: WhiteSur is a dependency of
  the session package with its licence noted in THIRD_PARTY.md; never copied into the repository. Dev sessions use it
  only if the owner installed it.
- **Cursors: option A.** `branding/cursors/` holds the original SVG sources (CC-BY-SA-4.0 like the other Grassfield
  assets, drawn for Grassfield, macOS-like proportions without copying macOS artwork): the CSS cursor names plus legacy
  aliases; a build step (`hyprcursor-util --create`, XCursor PNG sizes 24/32/48/64/96 through the existing build tooling)
  produces `grassfield-cursors`. Settings > Accessibility > Pointer (macOS model: size slider, fill and outline colour).
  Implemented: the size and the colours. The shell asks the compositor for the size with Hyprland's own
  `setcursor <theme> <size>` request on its own instance's request socket, a live redraw follows through the compositor
  capability `cursor-refresh` when the plugin has it (gfc/1 verb `hl.plugin.grassfield.cursor_refresh()`, plugin
  0.7.0-cursor: Hyprland's last named shape re-applied with force, so a pointer that does not move is drawn at the new
  size with the same shape and at the same place; never while it is hidden or a client draws its own cursor surface;
  `docs/specs/compositor.md` FR39-FR40), and the applications the shell starts get `XCURSOR_SIZE` and
  `HYPRCURSOR_SIZE` in their environment; running applications keep their size (documented limit).
  **Colours (owner decision 2026-10-19, macOS Accessibility > Display > Pointer: "Pointer outline color", "Pointer fill
  color", "Reset Color"; any colour is allowed, no contrast guard, as macOS):** the settings keys `pointer.outlineColor`
  (default `#ffffff`) and `pointer.fillColor` (default `#000000`), the two placeholders of the SVG sources. For any other
  pair the shell regenerates the theme: `branding/cursors/build.sh --name grassfield-cursors-custom --out <icons dir>
  --outline ... --fill ...` (SVG recolour, `hyprcursor-util --create`, XCursor PNG sizes) in a Process off the UI thread,
  debounced while a colour well is dragged (the final pair is always built), one build at a time (a newer pair terminates
  the running one), written atomically (build into a temporary directory, rename), then `setcursor
  grassfield-cursors-custom <size>` and the `cursor-refresh` redraw; "Reset Colour" switches back to `grassfield-cursors`
  and deletes the custom one. **The wanted theme is derived from the stored colours only, never from the session
  environment** (fix pass after review: when `cursor.lua` chose the custom theme at login because it existed on disk,
  Reset Colour was a no-op): `cursor.lua` always starts a real session with `grassfield-cursors`; the shell switches to the
  custom theme when its settings are read and the stamp (`colors`, written by build.sh inside the theme) names the stored
  colours, rebuilds when it does not, and at startup with default colours sends `grassfield-cursors` and deletes any
  custom theme. The theme on disk is identified by its stamp, not by a build counter; a build is its own process group
  (`setsid`) and is stopped as a group. A failed or impossible build (missing tool, no script, no directory) leaves the pointer as it is
  and the reason is shown in Settings. **`python`, `librsvg` (rsvg-convert) and `hyprcursor` (hyprcursor-util) are
  runtime dependencies of `grassfield-desktop`** (`depends=` in `packaging/arch/PKGBUILD`); the script, the sources and
  the table are installed under `/usr/share/grassfield/cursors`. The icons directory is `$XDG_DATA_HOME/icons`, else
  `$HOME/.local/share/icons` (hyprcursor and XCursor search `$HOME/.local/share/icons` and `$XDG_DATA_DIRS`); a dev
  session writes under `.dev/share/icons` only and refuses to build without that directory. Dev: only the nested instance
  is ever addressed.

## Consequences
- New shared component and settings keys; every icon call site moves to `TintedIcon` (one pass per surface).
- New asset folder `branding/cursors/` and build steps (hyprcursor-util and XCursor generation as build dependencies).
- GPL-3.0 WhiteSur is a separate package; the ISO (M6) must ship its source offer and licence; public release needs the
  E27 legal review again.
- Limits: tinted third-party icons are approximations; running GTK/Qt apps keep their cursor until restarted.
