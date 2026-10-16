# grassfield-ui spec · shell-engineer · M1 (spike S1)

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
No reference material exists yet (F1 pending). Every measurement is an estimate and carries a `source` note in `ui/tokens/tokens.json`.

## Purpose and non-goals
Design system shared by the shell and (later) native apps: tokens, frosted material, appearance state and the M1 component set (Icon, PopupMenu/MenuItem/MenuSeparator, Slider, Toggle, Button, Tooltip). Non-goals: Qt Quick Controls style (M4), any Quickshell or Hyprland import, business logic.

## Functional requirements
1. `ui/tokens/tokens.json` is the single source of truth; `ui/tools/gen-tokens.py` generates `Tokens.qml`; `--check` exits 1 when stale.
2. `Appearance` exposes `dark` (default true), `transparency` (default 0.25), `reduceTransparency` (forces effective transparency 0), `reduceMotion` (durations capped at `motionReducedMax` = 100 ms).
3. `Material` tint alpha = `1 - t * (1 - tintAlphaMin)`; adds top highlight, 1 px border and a gaussian shadow (`RectangularShadow`, QtQuick.Effects 6.9+, verified in Qt 6.11.2) masked so it never shows under the glass.
4. `Material` never blurs. The window declares `BackgroundEffect.blurRegion: Region { item: material; radius: material.radius }` when `material.blurActive`.
5. Font family Inter, fallback Noto Sans (first installed wins).
6. `Icon { name, color, size }` draws `branding/icons/symbolic/<name>.svg` (monochrome black) recolored with `MultiEffect` colorization (brightness 1 + colorization 1). `directory` is overridable for installed layouts.
7. `PopupMenu { model }` with `model: [{id, text, shortcut?, iconName?, enabled?, checked?, destructive?, separator?, submenu?}]`; signals `activated(item)` and `closeRequested()`. Rows: 22 px, 6 px radius, accent highlight on hover and keyboard selection, right-aligned shortcut, chevron for submenus, disabled at `material.disabledOpacity`. Keys: Up/Down/Home/End, Return/Space, Right (open submenu), Left (close), Esc. The navigation model is `MenuNav.js` (pure).
8. `Slider` (value, from, to, stepSize, `moved(value)`; arrow/Home/End keys), `Toggle` (checked, `toggled(checked)`; Space/Return), `Button` (primary/destructive), `Tooltip` (text, shown, delay). All have `Accessible` role/name, focus ring 2 px, Reduce Motion aware.

## grassfield.json keys (contract version 1; the integrator adds `config/schema/grassfield.schema.json`)
| Key | Type / range | Default | Used by |
|---|---|---|---|
| `version` | int | 1 | contract |
| `appearance` | `"dark"` \| `"light"` | `"dark"` | Appearance.dark |
| `material.transparency` | number 0–1 | 0.25 | Appearance.transparency |
| `accessibility.reduceTransparency` | bool | false | Appearance |
| `accessibility.reduceMotion` | bool | false | Appearance |
| `dock.pinned` | string[] (desktop entry ids) | `["foot","chromium","org.gnome.Nautilus"]` | Dock |
| `dock.magnification` | number 1–2.5 | 1.6 | Dock |
| `dock.magnificationEnabled` | bool | true | Dock |
| `dock.autohide` | bool | false | Dock |
| `notifications.dnd` | bool | false | Notifications (banners suppressed except critical), menu bar moon |
| `notifications.previews` | `"always"` \| `"unlocked"` \| `"never"` | `"unlocked"` | Notifications (`never` hides bodies) |

Location: `$GRASSFIELD_CONFIG_HOME/grassfield.json` (dev) else `$XDG_CONFIG_HOME/grassfield/grassfield.json`. The file is created on the first UI change (Control Center, Dock menu); setters clamp values, write atomically after 150 ms and the file is watched for external edits.

## Acceptance criteria
- A1 `gen-tokens.py --check` exit 0 (L0). A2 `tests/unit/tst_tokens.qml`, `tst_popupmenu.qml`, `tst_menunav.qml` pass (L0). A5 `tests/shell/settings_roundtrip` (real FileView) passes (L1). A3 `qmllint.sh` 0 warnings (L0). A4 nested screenshot shows blur at transparency 1 and an opaque surface at 0 (L2, manual scenario).

## Interfaces / contracts (versions)
Module `Grassfield.Ui` 1.0 (semver). Tokens JSON `version: 1`.

## Dependencies (verified versions)
Qt 6.11.2 (QtQuick, QtQuick.Effects). No Quickshell types.

## Degraded behavior
Compositor without ext-background-effect: surfaces stay tinted but unblurred (fallback via Hyprland layer rules is not implemented yet).

## Automated tests · Manual verification steps
`scripts/dev/test.sh`; nested `scripts/dev/shot.sh` with a striped wallpaper behind the bar at `material.transparency` 1 vs 0.

## Performance · Accessibility · i18n
Each Material with a shadow adds two offscreen layers and a MultiEffect mask; not measured (gate P* not run). Shell RSS after the M1 scenarios: see the S2 report. Legibility gate A2 not measured. Strings live in surfaces via `qsTr()`.

## Known limitations
- All values are estimates, not measured from the reference.
- Blur strength cannot grow with the slider: it is compositor-defined; only the tint changes.
- Light appearance is untested visually. Inter is not installed yet (Noto Sans is used).
- The shadow cut-out mask shows a faint dark artifact at one corner in the light appearance (visible in `cc-light`); not fixed.
- Submenus declare no blur region of their own.
- Qt has no per-glyph font fallback list in QML; the family is chosen once at startup.
