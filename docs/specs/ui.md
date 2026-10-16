# grassfield-ui spec · shell-engineer · M1 (spike S1)

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
No reference material exists yet (F1 pending). Every measurement is an estimate and carries a `source` note in `ui/tokens/tokens.json`.

## Purpose and non-goals
Design system shared by the shell and (later) native apps: tokens, frosted material, appearance state. Non-goals: components beyond Material, Qt Quick Controls style (M4), any Quickshell or Hyprland import, business logic.

## Functional requirements
1. `ui/tokens/tokens.json` is the single source of truth; `ui/tools/gen-tokens.py` generates `Tokens.qml`; `--check` exits 1 when stale.
2. `Appearance` exposes `dark` (default true), `transparency` (default 0.25), `reduceTransparency` (forces effective transparency 0), `reduceMotion` (durations capped at `motionReducedMax` = 100 ms).
3. `Material` tint alpha = `1 - t * (1 - tintAlphaMin)`; adds top highlight, 1 px border, diffused shadow outside the shape.
4. `Material` never blurs. The window declares `BackgroundEffect.blurRegion: Region { item: material; radius: material.radius }` when `material.blurActive`.
5. Font family Inter, fallback Noto Sans (first installed wins).

## Acceptance criteria
- A1 `gen-tokens.py --check` exit 0 (L0). A2 `tests/unit/tst_tokens.qml` passes (L0). A3 `qmllint.sh` 0 warnings (L0). A4 nested screenshot shows blur at transparency 1 and an opaque surface at 0 (L2, manual scenario).

## Interfaces / contracts (versions)
Module `Grassfield.Ui` 1.0 (semver). Tokens JSON `version: 1`.

## Dependencies (verified versions)
Qt 6.11.2 (QtQuick only). No Quickshell types.

## Degraded behavior
Compositor without ext-background-effect: surfaces stay tinted but unblurred (fallback via Hyprland layer rules is not implemented yet).

## Automated tests · Manual verification steps
`scripts/dev/test.sh`; nested `scripts/dev/shot.sh` with a striped wallpaper behind the bar at `material.transparency` 1 vs 0.

## Performance · Accessibility · i18n
Shadow is N (= `shadowBlur`) 1 px ring rectangles per Material; cheap but not measured (gate P* not run). Legibility gate A2 not measured. Strings live in surfaces via `qsTr()`.

## Known limitations
- All values are estimates, not measured from the reference.
- Blur strength cannot grow with the slider: it is compositor-defined; only the tint changes.
- Light appearance is untested visually. Inter is not installed yet (Noto Sans is used).
- Shadow is an approximation (rings), not a gaussian.
- Qt has no per-glyph font fallback list in QML; the family is chosen once at startup.
