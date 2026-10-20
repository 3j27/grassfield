# grassfield-ui spec · shell-engineer · M1 (spike S1)

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
No reference material exists yet (F1 pending). Every measurement is an estimate and carries a `source` note in `ui/tokens/tokens.json`.

## Purpose and non-goals
Design system shared by the shell and (later) native apps: tokens, frosted material, appearance state and the M1 component set (Icon, PopupMenu/MenuItem/MenuSeparator, Slider, Toggle, Button, Tooltip). Non-goals: Qt Quick Controls style (M4), any Quickshell or Hyprland import, business logic.

## Functional requirements
1. `ui/tokens/tokens.json` is the single source of truth; `ui/tools/gen-tokens.py` generates `Tokens.qml`; `--check` exits 1 when stale.
2. `Appearance` exposes `dark` (default true), `transparency` (default 0.25), `reduceTransparency` (forces effective transparency 0), `reduceMotion` (durations capped at `motionReducedMax` = 100 ms).
3. `Material` tint alpha = `Appearance.tintAlpha(t)`: `1 - t * (1 - tintAlphaMin)` (0.85 at the default t = 0.25), clamped to `tintAlphaClamp` up to `tintClampUntil` (A2: 0.82 up to t = 0.6), then linear to `tintAlphaMin` at t = 1; adds top highlight, 1 px border and a gaussian shadow (`RectangularShadow`, QtQuick.Effects 6.9+, verified in Qt 6.11.2) masked so it never shows under the glass.
4. `Material` never blurs. The window declares `BackgroundEffect.blurRegion: Region { item: material; radius: material.radius }` when `material.blurActive`.
5. Font family Inter, fallback Noto Sans (first installed wins).
6. `Icon { name, color, size }` draws `branding/icons/symbolic/<name>.svg` (monochrome black) recolored with `MultiEffect` colorization (brightness 1 + colorization 1). `directory` is overridable for installed layouts.
6a. `TintedIcon { source, size, mode?, tint?, oversample? }` draws an application or file icon (an image URL: a theme icon path, `image://icon/<name>`, a file URL) in the user's icon appearance mode, see "Icon appearance modes". Never for symbolic UI glyphs (`Icon` keeps those) or content (thumbnails, notification pictures).
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
| `dock.magnificationEnabled` | bool | false | Dock |
| `menubar.showBackground` | bool | false | Menu bar (transparent unless true) |
| `dock.autohide` | bool | false | Dock |
| `dock.recent` | string[] (desktop entry ids, newest first, at most `dock.recentMax` 3) | `[]` (owned by the Dock; written only when the list changes) | Dock |
| `dock.showRecents` | bool | true | Dock, Settings |
| `dock.minimizeIntoApp` | bool | false | Dock, Settings |
| `notifications.dnd` | bool | false | Notifications (banners suppressed except critical), menu bar moon |
| `notifications.previews` | `"always"` \| `"unlocked"` \| `"never"` | `"unlocked"` | Notifications (`never` hides bodies) |
| `icons.mode` | `"default"` \| `"dark"` \| `"clear"` \| `"tinted"` | `"default"` | `Appearance.iconMode` (ADR-0014; the ADR names it `appearance.iconMode`, see Icon appearance modes) |
| `icons.tint` | `"accent"` or `"#rrggbb"` | `"accent"` | `Appearance.iconTintSetting`, resolved to `Appearance.iconTint` |
| `icons.folderColor` | `"theme"` \| `"accent"` \| `"#rrggbb"` | `"theme"` | `Appearance.folderColorSetting`, resolved to `Appearance.folderTint` (see Folder colours) |

Location: `$GRASSFIELD_CONFIG_HOME/grassfield.json` (dev) else `$XDG_CONFIG_HOME/grassfield/grassfield.json`. The file is created on the first UI change (Quick Settings, Dock menu); setters clamp values, write atomically after 150 ms and the file is watched for external edits. The watch is Quickshell's `FileView` (inotify; unaffected by `QS_DISABLE_FILE_WATCHER`, which only turns off config hot-reload) and cannot start inside a directory that does not exist, so the store creates the config directory first and only then gives the `FileView` its path (real session 2026-10-20: on a fresh account the Settings app created the directory after the shell started and nothing applied until a restart). Every key is applied within about 1 s of an external atomic write; `tests/shell/settings_apply.sh` checks it with the real unit environment.

## Icon appearance modes (ADR-0014 phase 1, provisional)
Every Grassfield surface that shows an app or file icon draws it through `TintedIcon`: Dock (tiles and minimized badge), Apps panel, Search results, desktop icons, Overview (Space tile icons, window name pill), the About and Force Quit panels, and the file-type icons of Grassfield Files (list, icon, column, gallery views and Get Info). The mode is `Appearance.iconMode`, fed from `icons.mode` by the shell (`Settings.iconMode`) and by Files and Settings (they read `grassfield.json` and follow it live, no restart). Not tinted, as in macOS: symbolic glyphs (`branding/icons/symbolic`), the Files sidebar and toolbar glyphs, file thumbnails, notification pictures, drag images. The macOS 26 model, what each mode does to a theme icon (the theme has no separate glyph layer, so the effect is an approximation; numbers are the `iconMode` token group):
- `default`: the icon as is. No effect item exists (`Loader.active` is false): no extra render pass, no cost.
- `dark`: a darker plate with the glyph kept readable. Every channel is multiplied by `1 - darkColorization` (a black colorization, which keeps hues; an additive brightness cut turns light icons blue) with a small brightness lift and extra contrast so the dark parts stay legible. White plates become mid grey, colours are kept, alpha is kept.
- `clear`: desaturated (saturation -1), slightly lighter, contrast raised, drawn at `clearOpacity` (0.78) so the material shows through.
- `tinted`: the luminance of the icon mapped to a ramp of `icons.tint` (default: the accent colour): shadows become a deep shade of the tint, highlights the tint at full strength; alpha kept. Done with MultiEffect colorization 1 after a brightness and contrast stretch; the saturation stays at 0 because MultiEffect desaturates after colorizing, which would grey the tint out.
Implementation: `IconModes.js` (pure: mode and tint validation, mode -> MultiEffect parameters from the tokens), `IconEffect.qml` (one `MultiEffect`, no blur or shadow), `TintedIcon.qml` (an `Image` plus a `Loader` for the effect). In an effect mode the image keeps its decoded size (`size` x `oversample`) and only provides the texture, so the effect's texture does not change while a surface scales the item (Dock magnification); the quad is scaled by the GPU. The effect is per icon, not per container: a container layer would redraw the whole Dock or grid (labels, highlights, indicators) through the effect. A custom `qsb` shader was not needed for the look or the cost (see Measurements).
Settings key naming: ADR-0014 names the keys `appearance.iconMode` and `appearance.iconTint`, but contract version 1 already has `appearance` as a string (`dark|light|auto`), so a nested key cannot exist without a version bump. The keys are `icons.mode` and `icons.tint` (schema, defaults, `Store.js`, shell store, `tests/unit/tst_settingsstore.qml` parity, `tests/shell/settings_roundtrip`). `icons.tint` is validated as `accent` or `#rrggbb` (schema `pattern`; `scripts/dev/check-schema.py` does not evaluate `pattern`, the stores do). An invalid hand-edited value reads as the default.
Settings > Appearance > Icon appearance: four preview tiles (Default, Dark, Clear, Tinted; a sample icon drawn through the same `IconEffect`, selection ring, one focus stop, Left/Right/Up/Down change the choice, `Accessible` radio buttons) and a Tint colour row (Accent plus eight swatches; enabled only for Tinted, the caption names the colour or says why it is off). i18n en and fr.
Measurements (nested session, WhiteSur, 2026-10-19, GPU shared with other nested sessions, so noisy): idle CPU of the shell is 0.1-0.3 percent in every mode (sporadic 1-3 percent spikes in all modes, including default); 62 icons static: 0.0-0.3 percent client CPU in every mode, +6 MB RSS in effect modes; 62 icons all changing size every frame (worse than Dock magnification, which moves about 8): 83-96 percent in default and 83-88 percent in the effect modes (software-rendered nested output, the animation dominates); Apps open-to-first-frame (`apps open->visible`, 62 items, median of 8, three rounds): default 79-91 ms, dark 110-133, clear 110-134, tinted 88-134 (the effect items are created at the first show; budget P3 is 300 ms); shell RSS after start and one Apps open: default 403-405 MB, dark 407-410, clear 411-424, tinted 394-402 (within the run-to-run noise). A2: internal glyph-to-plate contrast (90th over 10th percentile luminance of the centre of each icon) on 35 Apps icons, 18 of which have 3:1 or more by default: dark keeps 16 of 18 (two borderline icons, 3.2 by default, drop to 2.0 and 2.4), clear 18 of 18, tinted 18 of 18; median ratio to default 1.09, 1.08 and 1.04. `tests/unit/tst_iconmodes.qml` covers mode -> parameters, tint resolution, the settings keys and the live switch.

## Folder colours (owner request 2026-10-19)
Folder icons are recoloured by a step separate from the icon modes: `FolderIcon { source, size, folderColor?, folderGlyph? }` wraps a `TintedIcon` (modes unchanged) and, when a colour applies, draws it through a layer with one `FolderEffect` (`MultiEffect`, colorization 1 over the luminance of the theme's folder; tokens `folderIcon*`). The colour is the folder's own (`folderColor`: `theme`, `accent`, `#rrggbb`, `""` = none) else the global `icons.folderColor` (`Appearance.folderColorSetting`); `theme` means the icon theme's own colour and creates no layer and no effect (`FolderStyle.recolors`). The optional `folderGlyph` is a `Text` over the effect, in a clipped box the size of the icon, at `folderIcon.glyphCenterY` with edge `glyphScale` x the icon: emoji opaque in their own colours, a plain symbol an engraved shade of the plate under it with >= 3:1 against the plate: the raw icon's pixels under the symbol are read once per icon file and size bucket and the plate of every mode, colour and appearance is computed from them with the MultiEffect arithmetic (`FolderPlate`, `FolderStyle.plateThrough`, `glyphShade`, `glyphMinContrast`; one engraving direction per icon mode; the symbol shows at once with an estimate and settles with a cross-fade; details and measurements in docs/specs/files.md); the symbol rule (one grapheme cluster, no control or bidi characters) is `FolderStyle.normalizeGlyph`, the same as the C++ side (one algorithm over generated data, `tests/fixtures/glyph-vectors.json`). `SwatchRow` puts its keyboard ring on the chosen swatch, else the first, as soon as it has the focus. `FolderStyle.js` is pure: validation (`theme|accent|#rrggbb`), precedence, folder icon names, the effect parameters from tokens, the parser of a folder's stored value, of `getfattr` output and of the per-user store (shell side, used by the desktop). The setting is `icons.folderColor` in the contract (schema `pattern`, defaults, `Store.js`, shell store, Files and Settings read it live); Settings > Appearance > Folder colour row (Theme, Accent, eight swatches). The per-folder storage, fallback and Customize Folder are specified in docs/specs/files.md. `tests/unit/tst_foldercolors.qml`.

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
