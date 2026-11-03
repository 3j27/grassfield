# ADR-0024: Visual direction: macOS 27 coherence, macOS 26 glass
Status: Accepted (owner decision 2026-10-25: « Je veux la cohérence de Golden Gate et l'approche glass de Tahoe »); the
values and the implementation plan below are the integrator's proposal, applied provisionally and refined on captures ·
Date: 2026-10-25 · Decider: owner (direction), integrator (values)

Amends master-prompt D5 and §5.5 ("frosted, restrained glass", "high-opacity tint", default transparency 0.25, "no
refraction or lensing"). Where §5.5 and this ADR differ, this ADR applies. Gate A2 is unchanged.

## Context
- `docs/audits/visual-tahoe-2026-10-25.md` measured the macOS 26 glass per surface. Section 2 shows that Grassfield draws
  every panel at a tint of about 0.82, where macOS 26 ranges from about 0 (Dock, Control Center modules) to near-opaque
  (widgets).
- `docs/audits/ui-finesse-2026-10-25.md` section 7 measured macOS 27 on release screenshots:
  - one window radius of 16.5–16.7 pt for every window;
  - sidebars edge to edge again, darker than the content, with coloured icons;
  - uniform toolbars ("actual bars");
  - a diffused window shadow with a contact edge;
  - a neutral Spotlight selection;
  - white text on the accent in both appearances;
  - darker edges and brighter specular highlights on the glass;
  - a Liquid Glass slider whose clear end is less clear than macOS 26.
- macOS 27 refined the structure and fixed inconsistencies of macOS 26: one radius instead of several, sidebars no
  longer nested inside the window corners, legible bars. It also made the glass more opaque. The owner wants the first
  without the second.

## Decision
**Structure, geometry, states and chrome follow macOS 27. Materials (how translucent surfaces look and how they adapt
to what is behind them) follow macOS 26.** Where a macOS 27 trait concerns both (the toolbar), the structure comes from
27 and the material from 26: a toolbar is a bar (27) drawn in clear glass with a scroll-edge effect (26).

### 1. From macOS 27 (coherence)
| Trait | Value (measured, ui-finesse §7) | Replaces |
|---|---|---|
| Window corners | one radius, about 16.6 pt (circle-equivalent at 45°), for every window: Grassfield apps, third-party windows, dialogs. Hyprland: `rounding = 20` at `rounding_power = 2.6` (≈ 1.24 × r) globally and in both rules. Inner shapes concentric with it | 26 / 12 (macOS 26) |
| Sidebars | edge to edge; light #ECECEC beside a white content area, no dividing line; coloured 20-pt icon tiles; selection 212 × 32, radius 8, 10 pt from both sidebar edges; search field a 28-pt capsule | flush grey sidebar with a line, monochrome glyphs (not the macOS 26 floating panel either) |
| Toolbars | bars, one height, a continuous bar under the controls once content scrolls under them | — |
| Menus | an icon only on the rows that have one, text otherwise about 16 pt from the edge; highlight 24 pt tall, about 5 pt from the sides, radius 7 (concentric with 12) | icon column in every menu, radius 6 |
| Accent fills | white text on the accent fill in both appearances; the dark appearance gets a deeper selection fill that holds 4.5:1 with white (A2) | dark text on a bright green in the dark appearance |
| Window shadow | the measured profile: Hyprland range 68, power 4, colour alpha 0.25, offset 0 16 (rendered as that model, note 2026-11-03); the contact edge, the window border's one device pixel: black 0.125 in the light appearance, black 0.58 in the dark one; the dark appearance's light inner rim deferred to the plugin (note 2026-11-03) | range 38, power 2, alpha 0.35, offset 0 14; white 0.15 border in both |
| Dark windows | neutral greys: window about #292929, groups about #313131 | #1D1F24 |
| Search | a neutral light fill on the selected row; result type about 17.7 / 15 pt | accent-filled row (F2c), 13 / 11 |
| Light window content | white windows, groups #F7F7F7 without a border, radius 12, margins 20 (unchanged from 26) | grey window, 14 % black groups with a border |
| Glass edge | darker outer edge and brighter specular highlight (27 refinement; it applies to the 26 glass below) | dark 1-pt rim and a 12-pt highlight band |

### 2. From macOS 26 (glass)
1. **Translucency per surface, not one tint.** Starting values at the default setting (light appearance; tint = white
   fraction over the blurred backdrop, ±0.1 from the earlier measurements, calibrated on captures):

   | Surface class | macOS 26 measured | Grassfield default | Why it can be that clear |
   |---|---|---|---|
   | Dock shelf | 0.00–0.04 | 0.05 | no text; the running dot gets its own contrast (a soft halo), not a tinted shelf |
   | Control Center modules, OSD | 0–0.2 | 0.15, adaptive (point 3) | labels and glyphs sit on white disks or follow the adaptive tint |
   | Overview band, widget gallery | 0–0.15 | 0.15 | thumbnails; labels on a plate |
   | Apps panel | 0.35–0.70 | 0.55, adaptive | labels on icons |
   | Notification cards, banners | 0.45–0.60 | 0.60 | text: A2 floor (point 4) |
   | Menus, Search | 0.56–0.76, backdrop hue | 0.65 | text: A2 floor |
   | Desktop widgets | near-opaque, light (244–255) | 0.92 | as macOS |
   | App windows | opaque | opaque, except the toolbar's scroll-edge glass (phase 3) | master-prompt §5.5 |

2. **Colour from the backdrop.** The tint is not a neutral grey plate: the blur raises saturation (Hyprland
   `blur.vibrancy`, today 0.18, to calibrate upwards) so that the glass takes the hue of what is behind it.
3. **Adaptive tint.** macOS 26 glass "adapts between light and dark environments". Grassfield raises a surface's tint
   when the backdrop under it is bright (dark text surfaces) or dark (light text surfaces), from the wallpaper luminance
   the shell already measures for the menu bar (ADR-0016 W6). Where a window may lie behind the surface (the shell does
   not see it), the worst case of the class is assumed.
4. **Gate A2 holds.** Text on glass keeps 4.5:1 at every slider value ≤ 0.6:
   - surfaces that carry text have a floor (about 0.6, computed per class and appearance by the A2 token test);
   - glyph-only and disk-carried content needs 3:1;
   - the slider is remapped: 0 = opaque (Reduce Transparency), the default = the table above, 1 = clearest. This also
     removes the dead zone between 0.25 and 0.6.
5. **Rims.** One device pixel each: a darker outer edge, then a brighter inner specular rim, stronger toward the light
   direction (top left), in both appearances. The 12-pt highlight gradient goes.
6. **Dark appearance glass.** Lighter than the backdrop and coloured by it: macOS 27 measures luminance 73–82 over a
   backdrop of about 40. The dark tint is a mid grey at the class alpha, with the adaptive rule of point 3 for bright
   backdrops. #1D1F24 at 0.85 (near black) goes.
7. **Refraction and lensing** (macOS 26's edge lensing) come later, compositor-side. Hyprland's main branch added
   swappable blur variants, including a "glass" finish with refraction and emboss (hyprwm/Hyprland #15661, 2026-08-22);
   no release carries it yet (latest v0.56.2). Grassfield adopts it once the Omarchy Hyprland ships it: Full
   performance profile only, measured against gate P3. Grassfield does not write its own refraction in the plugin unless
   that path fails.

## macOS reference
- macOS 27: one window corner radius for every window, sidebars built into the window, legible bars, and a slider from
  clear to frosted with the default at its midpoint (reviews, release screenshots).
- macOS 26: Liquid Glass that is clear on controls and navigation and frosted where text needs it. It adapts to its
  backdrop and refracts at its edges (Apple: "translucent and behaves like glass in the real world. Its color is
  informed by surrounding content and intelligently adapts between light and dark environments").

## Alternatives rejected
- Pure macOS 27 (more opaque glass): the owner chose otherwise.
- Pure macOS 26 (also its structure): inconsistent radii, sidebars nested inside window corners, bars that lose legibility.
  macOS 27 fixed these.
- One global tint (today): reads as solid grey plates next to the references (earlier audit, section 2).
- Dropping gate A2 for the clear look: A2 is a master-prompt gate; the adaptive tint and text floors keep it.

## Consequences
- Tokens: a per-surface tint set (light and dark) and its A2 test cases; `material.highlightOpacity` and the band
  replaced by rim tokens; new selection-fill tokens; dark window neutrals; `window.*` radii; shadow tokens mirrored in
  `config/hypr/grassfield/looknfeel.lua`.
- Code: `ui/Grassfield/Ui/Material.qml`, `Appearance.qml` (slider remap, adaptive tint), the hosts of each surface, the
  shell's wallpaper-luminance feed, `config/hypr/grassfield/{looknfeel,windows}.lua`, the apps' window, sidebar and
  group components, `MenuItem.qml` and `PopupMenu.qml`, the Search panel.
- Session: the window border colour follows the appearance (light: dark contact edge; dark: light rim), set by the
  session, not by the user's Hyprland.
- Gates: A2 (re-run per class and appearance), P3 (blur passes and vibrancy are GPU cost on i915; measure the Full,
  Balanced and Reduced profiles), F1 (owner side-by-side).
- Supersedes: `visual-tahoe-2026-10-25.md` priority 10 (floating sidebars) and its open material decision
  (per-surface tints: yes, at the values above); `ui-finesse-2026-10-25.md` F7's 26 / 12 targets.

## Owner decisions (2026-10-26)
Asked as questions with options after lot 2; the details are in the action plan, "Owner decisions".
- Gate F1: no difference even on a careful inspection, outside the hard limits accepted by name.
- Dark selection fill: #2E8049 for the Grassfield green (white 4.88:1), a derived shade per accent that keeps 4.5:1.
- Glass (§2): the adaptive tint (point 3) comes before any surface with text gets clearer; then the per-class tints.
- Symbols: heavier everywhere (an ADR-0003 amendment).
- Menu shortcuts: macOS symbols on a Mac, the text form on a PC (automatic, with a setting).

After the F1 validation against macOS 27 (2026-10-26, `docs/audits/ui-finesse-2026-10-25/f1-macos27.md`):
- Apps and Search take macOS 27's separate search capsule above their panel.
- Notification Center: the "Notification Center" title row with a round x, and collapsed groups drawn as stacks; the
  timestamps stay.
- Dark glass keeps the near-black tint (G-6 is not pursued: a lifted grey fails A2 with today's colours).
- The Dock shelf keeps 0.05 (macOS 26 glass).

## Plan (phases; each is a reviewed slice with `just check`, tests and `just shot`)
Item by item (files, values, verification): `docs/audits/ui-finesse-2026-10-25/action-plan.md`.

1. **Coherence (macOS 27):** window radius 20 at power 2.6 everywhere, after a nested 45° measurement; shadow and border
   per appearance; concentric inner radii; menus (row icons, 16-pt text, radius 7); white on the accent with a dark
   selection fill; dark window neutrals; light windows and groups; Settings and Files sidebars (tone, coloured tiles,
   selection); Search type and neutral selection; pixel-grid snapping (ui-finesse F5).
2. **Glass (macOS 26):** per-surface tints and their A2 tests; rims instead of the band; vibrancy; the adaptive tint
   from the wallpaper luminance; slider remap; Reduce Transparency and Increase Contrast mapped onto it.
3. **App chrome glass:** a toolbar scroll-edge effect inside app windows (Qt-side blur of the window's own content); the
   owner checks it before any wider use of glass in app windows.
4. **Lensing:** Hyprland's glass blur variant once released and shipped by Omarchy; Full profile only; P3 measured.

## Note (2026-10-29): the menu bar's band
Integrator decision under the owner's delegation, closest to macOS 26/27. The band the menu bar shows (the setting, the automatic assist of ADR-0016 D1, or a full-screen window) is glass of the "menu" class, and its tone adapts to the wallpaper strip under it (point 3), whatever the appearance: dark glass with light text over a dark strip, light glass with dark text over a light one. The unclassed material gave 0.82 at transparency 0.49. Over the owner's video strip (p5 0.0528, p95 0.35) the band is now dark glass at alpha 0.64 (0.65 at 0.25), judged at rest (7.73:1), under the open title's capsule (4.73:1) and dimmed (3.06:1); the appearance's own light glass would have needed 0.79. The strip is used only while it is what lies behind the bar (no window under it, no full-screen window); otherwise the surface keeps the appearance's material at the worst case. Reduce Transparency stays opaque in the appearance's colours. Detail: docs/specs/menubar.md item 0b.

## Amendment 2026-11-03 toolbar capsules have no dark rim

Section 2 point 5 (rims) governs `Material` glass: surfaces that blur the wallpaper behind them. The capsules of an app
window's toolbar (`RimmedCapsule`: back / forward, the view group, the search capsule) sit on an opaque window and blur
nothing. Measured on the macOS 27 Settings capture ss-004-005 (2 px/pt, 2026-11-03), the back / forward capsule is white
(#FEFEFE) with a white device-pixel edge and no darker outline: across its edge the pixels step from the shadow grey
(#F1F1F1 below, #F5F5F5 beside, #F7F7F7 above) straight to white, and the grey fades over about 14 px. The sidebar search
field is a flat #E1E1E1 on the #FAFAFA sidebar, with no rim and no shadow. The earlier reading of a dark rim at #BDBDBD was
the shadow's first pixel.

Decision: `RimmedCapsule` draws a white fill (`toolbar.capsuleFillOpacity` 0.7) lifted by a soft shadow
(`toolbar.shadow*`: blur 8, offset 2, opacity 0.10), and the field a flat tinted fill (`toolbar.fieldFillOpacity` 0.10); the
`toolbar.rimOpacity*` and `innerRimOpacity*` tokens are removed. Increase Contrast keeps the control outline. The dark
appearance values are estimates (no dark capture). Gate A2 holds: the capsule and field fills are still tested as backdrops
of the `window` role (tests/visual/test_contrast_tokens.py); white at 0.7 only lightens the light window. Blur is
untouched: a drop shadow is not blur and nothing is faked. A toolbar search field is a lifted white capsule like the
other toolbar items; only the sidebar's search is the flat field. Side effect: pink's accent ink is no longer needed (ADR-0040
amendment 2026-11-03).

## Amendment (2026-11-03): floating sidebars from macOS 26
Owner decision of 2026-11-02 (docs/STATE.md): **the sidebars float**, as the macOS 26 inset panel, replacing §1's "Sidebars"
row (edge to edge, flush). Everything else of §1 stands: the window corner, the window edge and shadow stay on macOS 27, and
the selection, search field and tile values of the old row are kept. Scope: Settings, Files and Preview (the Store's flush
sidebar follows in its own step; it already takes the calmer fill below).

Measured on the macOS 26 System Settings capture (system-settings ss-004-005, 2 px/pt, 1446 px = 723 pt wide; and the
Finder capture getting-started gs-010-011 at 1.0748 px/pt), 2026-11-03:

| Trait | Value | Token |
|---|---|---|
| Panel inset from the window's left, top, bottom edges | 8 pt (x 16, y 16 px; bottom 1785 of 1801 px); Finder 8-9 px | `window.sidebarPanelInset` 8 |
| Panel corner | 18 to 19 pt, concentric with the 26-pt window corner (26 - 8 = 18) | `window.sidebarPanelRadius` 18 |
| Panel width (Settings) | 215 pt, so a slot of 8 + 215 = 223 pt | `settings.sidebarWidth` 223 |
| Panel fill | 249 against the 252 content ground (the window edge is 255): 6 levels under the window; the dark appearance keeps its own 6 (no dark capture: estimate) | `color.light.sidebarFill` #F7F6F3 (was #EEECE7, 15 under); `color.dark.sidebarFill` unchanged #25231F |
| Rim | 1 pt (2 px at 2x), pure white (255) on the panel's edge, drawn as whole device pixels (1 px at 1.25) with its far edges snapped down, so it never splits between two pixels | `window.sidebarPanelRimWidth` 1, `window.sidebarPanelRimOpacity` 1.0 (dark: 0.08, estimate) |
| Shadow | soft, about 10 pt: 242 at the right edge fading to the 252 ground over 20 px, 240 to 243 below over 14 px, 244 in the left gutter; a drop shadow (`RectangularShadow`, z -1) on an opaque window, not blur | `window.sidebarPanelShadowBlur` 12, `ShadowOffsetY` 1, `ShadowOpacity` 0.08 (a blurred edge shows half: black 0.04; dark 0.3, estimate) |
| Lights | first centre at (25.75, 25.75) from the window corner: inside the panel, 17.75 pt from its edge | unchanged `window.unifiedLightCentre` 26 |
| Selection pill | 195 x 32 pt, 10 pt from the panel's edges, radius about 9 (kept 8), accent fill | unchanged `settings.sidebarInset` 10 |
| Search field | 195 x 28 pt, top at 61 pt, 10 pt inset | unchanged |
| Content beside the panel | the toolbar capsule 8.5 pt right of the panel; groups 20 pt from it | the slot ends at the panel's right edge |
| Finder sidebar icons | monochrome, #2A3135 (the label's own dark), not the accent | the text colour; `accentInk` only on the selected row |

Decisions:
- **Material.** An app window is opaque, so the panel is an opaque fill at the measured value; there is nothing behind it to
  blur, and nothing is faked. Real translucency would need a per-region compositor effect: not done (the macOS 26 panel is
  glass over a window that is itself the wallpaper's tint; ours reads the same on an opaque window).
- **Calm.** The light panel is 6 levels under the window instead of 15, so the sidebar stops being the heaviest area. The
  lighter ground lets the light pink accent hold 4.5:1 on its own (4.92:1 at the worst, on the bare sidebar, since the capsules turned white), so `color.accentInkLight.pink` goes;
  yellow and green keep their ink. A2 (white on the accent fill, 4.5:1) is unchanged.
- **Inactive window.** The sidebar tiles of Settings turn a mid grey (`settings.sidebarTileInactiveLight` #8C8A86, 3.45:1 under the white glyph; the lights' #D4D1CC was 1.52:1; dark #5C5A56, 6.88:1; pinned by `test_inactive_sidebar_tile_keeps_the_glyph_at_3_to_1`) and the selection pill goes neutral
  (already); the Files sidebar's selected icon turns from the accent to the text colour.
- **Preview.** Its toolbar spans the window, so its lights stay in the toolbar above the panel; moving them into the panel is
  the Preview alignment step.
- **Component.** `SidebarPanel` (Grassfield.Ui) draws the panel, so the three apps share one shape and one rim.
- **Open and Save panels.** The portal's panel (Files `FilePanel`) takes the same floating sidebar, as macOS's panel has one;
  it has no lights, so the rows start one inset and one gap inside the panel.

## Amendment (2026-11-03): colour life, where vivid and where darkened (refinement batch 5)

A2 asks 4.5:1 for text on an accent fill, which is why `color.accentLight` is darkened. It never asked that of a colour under
no text, and the darkened values made Settings read muddy beside macOS (docs/audits/refinement-2026-11-02.md § 08, § 09-11,
§ 05-07). The rule from now on:

- **Vivid, where no text sits.** Settings icon tiles (`color.tile.<name>` bottom and `<name>Top`, a soft vertical gradient,
  `TileGradient`), the Appearance accent swatch discs (`color.swatch.<accent>`), the window lights (`window.closeColor`,
  `minimizeColor`, `zoomColor`, shared with the compositor plugin through `ThemeTokens.hpp`).
- **Vivid but our own (ADR-0003, docs/legal/visual-review.md E18, E34).** The macOS captures were measured at 2 px/pt
  (ss-004-005, ss-010-037, ss-032-145) for saturation and lightness only. Copying them (a first version did) is a 1:1 copy,
  which the owner's E18 acceptance does not cover (it covers shifted colours, CIE76 dE 7.9 to 29.5). Every value is shifted in
  hue and lightness to dE 9 or more from every known macOS system colour: `test_no_token_copies_a_macos_system_colour`
  (greys and near-blacks, the warm neutrals of ADR-0040, are exempt).

  | Role | Own value (top / bottom, or disc) | Measured macOS (not used) |
  |---|---|---|
  | Lights close, minimize, zoom | `#E83A52`, `#E6C619`, `#2DC47A` | `#FF5C60`, `#FAC800`, `#35C759` |
  | Tile blue | `#0097FC` / `#007CCE` | `#45A7FF` / `#0088FF` |
  | Tile green | `#2CA84B` / `#22843B` | `#6CDB81` / `#34C859` |
  | Tile red | `#FF5D38` / `#FF3B0F` | `#FF6667` / `#FF383C` |
  | Tile pink | `#FF538B` / `#FF2C71` | `#FF5F7D` / `#FF2C55` |
  | Tile purple | `#8568FF` / `#6142F4` | `#887CFF` / `#6155F5` |
  | Tile cyan | `#039FC9` / `#027B9B` | `#73DDF9` / `#03BFE7` |
  | Tile orange | `#F66702` / `#C85402` | `#FDAB5D` / `#FD8D26` |
  | Tile graphite, black | `#8F8D88` / `#7A7873`, `#3A3835` / `#100F0D` (dark `#6A6863` / `#46443F`) | greys: exempt |
  | Swatches blue, purple, pink, red, orange, yellow, green | `#0167FD`, `#783B93`, `#F54C85`, `#DE3651`, `#F56A16`, `#FCEA21`, `#7FB844` | `#0178FD`, `#923B93`, `#F54C9C`, `#DE363B`, `#F58016`, `#FCC521`, `#60B844` |

- **Darkened (A2), where text sits.** Selection pills, buttons with labels, focus rings and every accent fill that carries text
  keep `color.accentLight` / `accentDark` and `color.selectionDark`: unchanged.
- **The glyph floor.** The white glyph on a tile is a graphic and holds 3:1 on the gradient's lightest point (its top):
  every top holds 3.05:1 or more (`test_vivid_tile_gradients_keep_the_glyph_at_3_to_1`); green, cyan and orange are darkened
  further to get there.
- **Tiles read against the panel (reviewer, batch 5).** Every tile end holds 1.5:1 on the sidebar panel in both appearances.
  The dark black tile is `#6A6863` / `#46443F` (the reviewer's `#5E5C57` / `#3A3835` was 1.34:1 at the bottom) with a
  1-device-pixel inner rim, white at `settings.sidebarTileRimOpacityDark` 0.12, snapped to device pixels (`Main.qml`).
  Graphite has a real step (4.41:1 at the bottom).
- **Inactive windows** keep grey tiles (`settings.sidebarTileInactiveLight` `#96948F`, 3.03:1 under the glyph; dark `#46443F`,
  9.73:1) and grey lights (`window.inactiveLight*`). An inactive tile never reads stronger against the panel than the
  weakest lit end (`test_tiles_read_against_the_panel_and_inactive_is_never_stronger`).
- **Dark appearance.** The macOS captures are all light; the same vivid tiles are used in both appearances except black.
- **Hover glyph of a light** is black at `window.glyphOpacity` 0.62, which holds 3:1 on each light (the close light was 2.64:1
  at 0.5; `test_vivid_lights_keep_their_glyph_legible`).
- **Swatch ring.** The chosen swatch's ring is its own vivid colour where that holds the focus ring's contrast on the window,
  else the accent colour (`AccentPicker.qml`). The Storage page's bar and legend use the same vivid tile colours as its row tiles.

## Note (2026-11-03): the window edge and shadow, measured on the GPU
The owner's decision of 2026-11-02 ("Golden Gate 27"): the window edge and shadow follow macOS 27, not the Tahoe 26
captures that `docs/audits/refinement-2026-11-02.md` (03-windows-corner-shadow, item 1) compared them with. That audit had
not checked the real GPU; `tests/compositor/window_edge.sh` now does: a Settings window on flat wallpapers (#E6E6E6,
#808080), GF-REF at 1.25, light and dark, active and inactive, the darkening of the backdrop per device pixel along the
middle of each side (`tests/compositor/edge_measure.py`, which holds the target below).

**The macOS 27 target.** Measured on three 512 Pixels Golden Gate window crops (Settings General, Finder Home, Force Quit;
the shadow is their alpha channel, 2 px per pt), which agree within 0.005. Darkening (black's alpha) against pt from the
window's edge:

| | contact (0-0.5) | 1 | 2 | 4 | 8 | 12 | 16 | 24 | 32 | 40 | 48 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| sides | 0.374 | 0.190 | 0.182 | 0.167 | 0.137 | 0.108 | 0.083 | 0.044 | 0.020 | 0.009 | 0.003 |
| top | 0.277 | 0.066 | 0.062 | 0.051 | 0.038 | 0.025 | 0.018 | 0.007 | 0.002 | 0 | 0 |
| bottom | 0.474 | 0.320 | 0.313 | 0.302 | 0.275 | 0.244 | 0.213 | 0.152 | 0.094 | 0.052 | 0.025 |

- The contact edge: one device pixel (half a point) that darkens the shadow under it by 0.20 on every side; 0.18 for an
  inactive window (Finder App Switcher capture).
- The dark appearance (Appearance Dark captures, over the wallpaper): an outer device pixel of black 0.92 over the shadow
  (0.83 inactive), then two device pixels (1 pt) of white 0.10 inside the window (0.08 inactive).
- The light appearance has no visible inner rim (at most white 0.07 over one device pixel, on the sidebar).
- Inactive shadow (low confidence: a gradient wallpaper): about 0.13 at 4 pt, 0.06 at 8 pt, gone by 16 pt.

**Ours before (main 293a5d55, Hyprland 0.56.2).** The render is Hyprland's model (`shadow.glsl`: alpha × (1 − d / range) ^
power outside the window box moved by the offset), within 0.012 beside the window, 0.005 above and 0.023 below. Range and
offset are in points at 1.25. So C-3 renders as fitted.
- Shadow, active, at 1, 4, 8, 16, 24 and 32 pt: sides 0.243, 0.213, 0.165, 0.087, 0.048 and 0.022 (27: 0.192, 0.172,
  0.142, 0.082, 0.047, 0.022). Bottom: 0.252 flat to 16 pt (27: 0.322 down to 0.212), then 0.174, 0.100 and 0.026 at 24,
  32 and 48 pt (27: 0.157, 0.099, 0.027).
- Contact edge: the 1-pt border is ONE device pixel (0.8 pt) at 1.25, black 0.25 over the shadow, 0.44 in all. That is
  twice macOS 27's darkness per point (0.2 over half a point).
- Dark appearance: a white 0.15 pixel outside the window, no dark edge, no inner rim.
- The audit's "77 % of the background ten points out" is below the window, where macOS 27 is at 74 % (0.26). The Tahoe 26
  capture's 95 % is 26's lighter shadow. The excess against 27 was the contact edge and the flat bottom.

**Fit.**
- Shadow values unchanged. They remain the least-squares fit of one offset box to the 27 profile: rms 0.0139 over the three
  sides. The best of a grid over range 30-100, power 1-6 and offset 0-24, with the alpha solved, is 0.0135 (range 94, power
  6, alpha 0.26, offset 16): no visible gain.
- What Hyprland's model cannot draw: 27's slope under the window. The box holds its alpha over the offset's 16 pt, where 27
  goes from 0.34 to 0.21: the plateau, at most 0.07 off. Its sides also start at 0.24 where 27 has 0.19 (0.05 off at the
  first pixels). Closer needs a second shadow or a shader of our own, not in this batch.
- Edge: the same darkness per point as 27's half-point line, drawn in Hyprland's one device pixel (0.8 pt at 1.25).
  Light: black 0.2 × 0.5 / 0.8 = 0.125 (inactive 0.11). Dark: black 0.92 × 0.625 = 0.58 (inactive 0.52).
- The values are tokens, `window.edge*`. The config holds the dark appearance's pair
  (`config/hypr/grassfield/looknfeel.lua`); the shell pushes the current appearance's (`Minimized.edgeCall`).

**The dark inner rim: tried with Hyprland's inner glow, deferred to the plugin.** Hyprland 0.56's inner glow
(`decoration.glow`, range 1, render_power 1) draws over the window content and lit the first device pixel inside every
window at half its colour's alpha (white 0.25 gave 0.125, the same light per point as 27's 0.10 over 1 pt). The nested
review (2026-11-03) failed it:
- On every third-party window with the plugin's titlebar, the glow follows the client surface (the bar is a decoration
  outside it). It lit the client's top row right under the bar's hairline: the separator became two light lines (74, then
  63, against 40 and 36), the second stopping about 22 px short of each side. The bar's top and sides got no rim, and the
  side rims started 16 pt below the bar.
- Hyprland 0.56.2 limits: no window rule scopes the glow (so the config cannot leave those windows out), and the glow is not
  drawn along the rounded corners (34 or less on the 20-pt arcs against 62 on the straight edges, where macOS 27 keeps the
  rim continuous).
- Decision (integrator, closest to macOS 27 with nothing broken): ship the per-point edge without the rim; the glow stays
  at Hyprland's default (off). The plugin is to draw the rim in a later compositor batch, with its bar: continuous round
  the corner arcs and over the bar, masking the client's top row under it.
- The dark edge without the rim, measured (levels, active): over #E6E6E6 the window 38, the contact pixel 72, the shadow
  174; over #808080, 38, 40 and 97. macOS 27 (Notes): window 41, rim 62, outer pixel 11, shadow 153. Against the backdrop the
  pixel takes the same darkness per point as 27's; against a dark window it reads as a soft step (lighter than the window
  over light backdrops, merged with it over mid-tones), not as a hard line, so 0.58 is kept. What the missing rim loses is
  the window's separation over dark backdrops.

**After (GF-REF 1.25, with and without the plugin).**
- Light contact edge: 0.138 over the shadow (0.348 in all) on the sides and 0.128 above and below; inactive 0.111.
- Dark: outer pixel 0.586 over the shadow (inactive 0.520); no rim in either appearance.
- The shadow as before. The same with the plugin unloaded: the edge and the shadow are Hyprland's and the shell's.

**Limits.**
- Other scales: the border is a whole number of device pixels (one at 1 and 1.25), so the edge there is up to 25 % darker
  per point than at 1.25.
