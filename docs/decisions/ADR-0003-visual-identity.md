# ADR-0003: Visual identity, fonts and reference-measurement method
Status: Proposed (applied provisionally) · Date: 2026-10-17 · Decider: owner · Needs legal review before any public release (§14)

## Context
D5: near-identical macOS 27 layout, proportions, typography scale, spacing and motion, with a frosted,
low-transparency material and a transparency slider; all assets Grassfield's own; no Apple assets ever.
SF Pro and SF Symbols are Apple-licensed and must not be used or redistributed.

## Options (font)
1. **Inter (SIL OFL 1.1, `inter-font` 4.1 in Arch extra)** — neo-grotesque designed for UI, metrics and
   weight range close to SF Pro, variable font with optical sizes (Inter Display).
2. Noto Sans (OFL) — installed already, wider and less "Apple-like".
3. Cantarell / Liberation — further away.

## Decision
- **UI font**: Inter (text) with Inter Display for ≥ 20 px; fallback chain `Inter, Noto Sans, sans-serif`.
  Monospace: the generic `monospace` family (`Tokens.typographyMonoFamily`); JetBrains Mono is not used
  (not installed, no reference in the code). Owner installs `inter-font`.
- **Session-wide font (owner request 2026-10-21, "a free font close to macOS's")**: Inter everywhere in the Grassfield
  session, not only in Grassfield's own UI. Nothing is vendored: `inter-font` stays a package dependency.
  - `packaging/fontconfig/fonts.conf` (installed as `/usr/share/grassfield/fontconfig/fonts.conf`) is selected through
    `FONTCONFIG_FILE` by `packaging/uwsm/env-grassfield` (readability-guarded; the Omarchy session never sets it). It
    includes `/etc/fonts/fonts.conf` (the user's own fontconfig and Omarchy's rules still load). The family rules sit
    BEFORE that include and insert Inter in place (`mode="prepend"`, just before the matched name) for `sans-serif`
    ("sans", "Sans Serif" included), `system-ui`, `-apple-system`, `BlinkMacSystemFont`, `SF Pro`, `SF Pro Text` and
    `.AppleSystemUIFont`, and Inter Display for `SF Pro Display`. A real family earlier in a list keeps its place, and
    Omarchy's later in-place `assign` of Liberation Sans over `sans-serif` lands behind Inter. The generic names stay in
    the list, so the CJK, Arabic and emoji alias chains still fire. These are family-name aliases only; no Apple font is
    used or shipped (needs legal review: see E29 in docs/legal/visual-review.md).
  - Missing families: a family that is not installed (Segoe UI, Cantarell, ...) falls back to Inter. One rule appends a
    weak Inter to patterns that name no generic family; because the system rules give such a family the default
    `system-ui` and Omarchy's rules then put a strong Liberation Sans behind it, a second rule after the include puts a
    strong Inter just before that `system-ui`. Known serif, mono and sans names carry their own generic and are not
    touched (Georgia stays Liberation Serif). `monospace`, `serif`, Helvetica, Arial, Times New Roman and Courier New are
    not touched: the terminal font stays the user's, and metric-compatible substitutes keep documents laid out.
    Finding of the test (tests/shell/fontconfig_session.sh): a strong append alone breaks serif fallbacks and the
    `default` metric aliases (Arimo), and a weak one alone loses to Omarchy's strong Liberation Sans; hence the pair.
  - Optical size: a request whose first family is Inter and whose `pixelsize` is >= 20 gets Inter Display first.
    Requests without a pixel size (some Qt paths) stay on Inter text.
  - Rendering: antialias on, `hintslight`, `rgba none`, `lcdfilter none` (grayscale, sharp on 1x). Closest to the
    reference's grayscale text without LCD fringes.
  - GTK: `packaging/dconf/grassfield.d/10-fonts.conf` sets `font-name` and `document-font-name` to `Inter 10` (10 pt = 13.3
    px at 96 dpi, the reference's 13 px body; Adwaita's 11 pt would be 14.7 px), `font-antialiasing` grayscale,
    `font-hinting` slight. Defaults, not locks (only icon-theme is locked). Qt: its generic theme asks for "Sans Serif"
    (fontconfig, now Inter) and `QT_QPA_PLATFORMTHEME=gtk3` reads `font-name`; nothing else is needed.
  - Tracking: Inter's "dynamic metrics" (rsms.me/inter lab, `InterDynamicTracking`, text family): tracking in em =
    -0.0223 + 0.185 * e^(-0.1745 * px) (display family: -0.015 + 0.17 * e^(-0.12 * px), not used yet).
    `Tokens.typographyTracking{A,B,C}` and `Appearance.tracking(px)`; applied in Grassfield.Ui's Button, MenuItem,
    Tooltip and SwatchRow. There is no central Text component, so other call sites keep Qt's default tracking.
  - User hook: `~/.config/grassfield/fonts.conf` (`$XDG_CONFIG_HOME`, ignored when missing) is the last element and wins
    over every rule above, family choice and rendering included; it is the supported way to override the session font.
    Omarchy's in-place `assign` of `sans-serif` does not win over Inter (Inter is part of the Grassfield look,
    integrator decision 2026-10-21). A user rule in `~/.config/fontconfig` that uses `prepend_first` on `sans-serif` still
    wins, because it goes to the very front of the list; that is intended, an explicit front-of-list rule is the user's choice.
  Evidence: tests/shell/fontconfig_session.sh, tests/shell/dconf_profile.sh.
- **Icons**: Grassfield's own line icon set in `branding/icons/` (SVG, CC-BY-SA-4.0 or CC0 — decided in
  ADR-0005), style: rounded caps, 1.5 px stroke at 16 px, optical alignment like the macOS menu bar. App
  icons come from the user's icon theme; Grassfield ships no app icons that imitate Apple's.
- **Traffic lights**: own glyphs and own colors (close #E5534B, minimize #D9A93B, zoom #4FA64F), shown
  without symbols until hover, then own symbols (×, −, ⤢). Recorded in `docs/legal/visual-review.md`.
- **Material**: frosted "restrained glass" (§5.5): blur from ext-background-effect-v1 (`BackgroundEffect`)
  or Hyprland layer-rule blur, then tint alpha = `mix(0.94, 0.62, transparency)` (dark) — exact curve in
  `ui/tokens/tokens.json`; default transparency 0.25; 0 = opaque (= Reduce Transparency).
- **Wallpapers**: generated by Grassfield (procedural gradients) or commissioned/CC0 with provenance in
  `branding/LICENSES.md`.
- **Names**: Overview, Search, Files, Apps, Stages (never Apple trademarks).

## Reference-measurement method
1. The owner places screenshots/recordings of macOS 27 in `design/reference/` (gitignored, never committed).
   File names: `<surface>-<appearance>-<scale>x.png`.
2. Measurements are taken at 1x logical points (divide 2x Retina pixels by 2) with a pixel ruler; each token
   records `source: "<file>, measured <date>"` or `"estimate, pending F1"`.
3. Grassfield screenshots are taken in the nested session on the GF-REF output (1920x1080, scale 1) with a
   fixed wallpaper and transparency 0.25, then compared side by side (gate F1, ±1 px).
4. Until the owner supplies references, tokens are marked as estimates and F1 stays NOT VERIFIED.

## Evidence
`pacman -Si inter-font` → extra 4.1-1, license OFL-1.1-RFN (2026-10-17). `fc-list` → Inter not installed.

## Consequences
- The "Reserved Font Name" clause of OFL-RFN: we ship Inter unmodified; if subsetted/modified, rename.
- Trade-dress risk remains with a near-identical layout → repository private until the M5 legal review.
