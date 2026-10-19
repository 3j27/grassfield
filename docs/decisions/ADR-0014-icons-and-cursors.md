# ADR-0014: Icon appearance modes with live tint, and Grassfield's own cursor set
Status: Proposed (owner request 2026-10-19; applied provisionally) · Date: 2026-10-19 · Decider: owner

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
  (a dark tinted plate with a tint-coloured glyph, a light tinted plate with a dark tint glyph in the light appearance; alpha kept). Implemented with a custom `qsb` fragment shader (`ui/Grassfield/Ui/shaders/icon.frag`): MultiEffect (colorization, saturation,
  brightness, contrast) could not reach the macOS 26 look (a white plate only went from 248 to 210 in Dark; Tinted gave a
  bright tint-coloured plate), so the shader separates plate and glyph per pixel (plate colour from probes inside the
  icon, membership by colour distance) and maps each mode (algorithm and limits: docs/specs/ui.md, "Icon shader").
  Effects exist only when the mode is not `default` and only for icons that are shown: one effect item per visible icon
  (not one shared pass per surface: a container layer would redraw labels, highlights and indicators through the effect). Phase 2 (later, own review):
  a generated tinted theme for third-party apps, regenerated in the background.
- Settings keys (settings contract, versioned): `icons.mode` (`default|dark|clear|tinted`, default `default`),
  `icons.tint` (`accent` or `#rrggbb`, default `accent`). (Implemented 2026-10-19 under `icons.*` because `appearance` is
  already a string key in contract version 1.) Settings › Appearance gets the mode and tint controls (macOS 26
  layout). The shell and Grassfield apps react live.
- Base theme: Grassfield sets the icon theme name for its session and for the shell (Quickshell's IconTheme pragma or
  `QT_ICON_THEME`/environment, whichever the installed version supports — verify), with WhiteSur first and the
  freedesktop fallback chain (`hicolor`, then the system theme) for missing icons. Packaging: WhiteSur is a dependency of
  the session package with its licence noted in THIRD_PARTY.md; never copied into the repository. Dev sessions use it
  only if the owner installed it.
- **Cursors: option A.** `branding/cursors/` holds the original SVG sources (CC-BY-SA-4.0 like the other Grassfield
  assets, drawn for Grassfield, macOS-like proportions without copying macOS artwork): the CSS cursor names plus legacy
  aliases; a build step (`hyprcursor-util --create`, XCursor PNG sizes 24/32/48/64/96 through the existing build tooling)
  produces `grassfield-cursors`. Settings › Accessibility › Pointer (macOS model): size slider, fill and outline colour;
  a change regenerates the theme into `$XDG_DATA_HOME/icons/grassfield-cursors-custom` and switches Hyprland to it; GTK
  and Qt apps pick up the XCursor theme on their next start (documented limit). Dev: only the nested instance is ever
  switched (scripts/nestctl).

## Consequences
- New shared component, a committed compiled shader (`scripts/dev/build-shaders.sh`, checked by `just check`) and settings keys; every icon call site moves to `TintedIcon` (one effect item per visible icon).
- New asset folder `branding/cursors/` and build steps (hyprcursor-util and XCursor generation as build dependencies).
- GPL-3.0 WhiteSur is a separate package; the ISO (M6) must ship its source offer and licence; public release needs the
  E27 legal review again.
- Limits: tinted third-party icons are approximations; running GTK/Qt apps keep their cursor until restarted.
