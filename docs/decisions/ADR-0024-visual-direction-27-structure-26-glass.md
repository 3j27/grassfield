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
| Window shadow | the measured profile: Hyprland range 68, power 4, colour alpha 0.25, offset 0 16; a dark contact edge through the window border in the light appearance (about black 0.25), a light inner rim in the dark one | range 38, power 2, alpha 0.35, offset 0 14; white 0.15 border in both |
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
