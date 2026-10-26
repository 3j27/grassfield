pragma Singleton
import QtQuick

// Appearance state shared by every Grassfield surface. The shell (or an app) feeds
// the user-facing settings in; surfaces only read the derived values below.
QtObject {
    // User settings (set by the host).
    property bool dark: true
    // Set by the first icon effect whose shader fails to load: no other icon creates an effect item then (the plain icon is
    // drawn, and Qt logs the failure once, not once per icon).
    property bool iconShaderBroken: false
    property real transparency: Tokens.materialDefaultTransparency
    property bool reduceTransparency: false
    property bool reduceMotion: false
    // Increase Contrast (Settings > Accessibility > Display): stronger borders and separators (the tokens that carry an
    // `increaseContrast` value), secondary text in the primary colour.
    property bool increaseContrast: false
    // Text size multiplier (1 to 1.3, Settings > Accessibility > Display): the tokens marked `textScale` follow it.
    property real textScale: 1
    // An opaque app window (Settings, Files): the window's own background and a lighter secondary text replace the
    // material's tint and the A2-darkened secondary text (those are for text over a blurred wallpaper). The shell never sets it.
    property bool windowSurface: false
    // Icon appearance (ADR-0014): default | dark | clear | tinted, and the tint setting ("accent" or "#rrggbb").
    property string iconMode: "default"
    property string iconTintSetting: "accent"
    // Folder colour (`icons.folderColor`): "theme" (the icon theme's own), "accent" or "#rrggbb".
    property string folderColorSetting: "theme"
    // Accent colour (`accent.color`): "multicolor" (the Grassfield green) | blue | purple | pink | red | orange | yellow | green | graphite.
    property string accentSetting: "multicolor"

    // A sample app icon (an SVG shipped with this module) for the icon appearance previews: it goes through the same
    // TintedIcon pipeline as every icon.
    readonly property url iconSampleSource: Qt.resolvedUrl("samples/icon-sample.svg")

    // Derived values.
    // Tint of the Tinted icon mode: the chosen colour, the accent by default.
    readonly property color iconTint: IconModes.tintColor(iconTintSetting, colors.accent)
    // Colour of folder icons for the global setting (the accent for "accent"); only meaningful when it recolours.
    readonly property color folderTint: FolderStyle.colorOf(folderColorSetting, colors.accent)
    // Reduce Transparency is equivalent to transparency 0 (opaque tinted surfaces).
    readonly property real effectiveTransparency: reduceTransparency ? 0 : clamp01(transparency)
    // Hairline alpha: the light appearance uses a lighter line (F1 gap 18).
    readonly property real separatorOpacity: dark ? Tokens.materialSeparatorOpacity : Tokens.materialSeparatorOpacityLight
    // Control fill alpha (push button, field, segmented track, unchecked box): the light appearance draws a light grey, not a
    // dark well (ADR-0024).
    readonly property real fillOpacity: dark ? Tokens.materialFillOpacity : Tokens.materialFillOpacityLight
    readonly property var colors: devGlyphMode !== "" ? glyphColors(baseColors) : baseColors
    // The palette of the appearance with the chosen accent applied (accent and accentText), live.
    readonly property var baseColors: dark ? accentedDark : accentedLight
    // Both carry `selection` and `selectionText`: the fill and the text of a selected row, a default button or a checked box,
    // the light accent with its text in both appearances (Accent.withSelection).
    readonly property var accentedDark: Accent.withSelection(Accent.contrastBoost(Accent.apply(Tokens.colorDark, accentSetting, true, Tokens), increaseContrast), accentedLightBase)
    readonly property var accentedLight: Accent.withSelection(Accent.contrastBoost(accentedLightBase, increaseContrast), accentedLightBase)
    readonly property var accentedLightBase: Accent.apply(Tokens.colorLight, accentSetting, false, Tokens)
    // The keyboard focus ring: the accent, or the text colour where the accent does not hold 3:1 against the material (Accent.focusRing).
    readonly property color focusRingColor: Accent.focusRing(baseColors.accent, windowFill, baseColors.text, Tokens.controlFocusRingMinContrast)
    // Control fills (audit 2026-10-25, priority 6). Dark appearance: the translucent fill of the material, as before. Light
    // appearance (macOS): chips white, secondary push buttons about 6 % grey, wells (the Apps field, Force Quit list, Overview add
    // button) white and translucent, none with a dark stroke.
    readonly property color chipFill: dark ? withAlpha(colors.fill, Tokens.materialFillOpacity) : withAlpha(colors.chipFill, Tokens.materialChipFillOpacityLight)
    readonly property color buttonFill: withAlpha(colors.fill, fillOpacity)
    readonly property color lightWellFill: withAlpha(colors.chipFill, Tokens.materialWellFillOpacityLight)

    // The fill that app windows draw as their own background (Settings, Files: `windowSurface`); the shell's materials, and the
    // menus, sheets, tooltips and combo popups that Grassfield.Ui draws in an app, keep `colors.materialTint` (ADR-0024 lot 1).
    readonly property color windowFill: windowSurface ? colors.windowBackground : colors.materialTint

    // Secondary text drawn directly on the opaque window surface or on its group fill (Settings): the lighter app-only grey, as
    // macOS. Text on a field, tab or chip fill keeps `colors.textSecondary`, which holds 4.5:1 on those fills (A2); outside an
    // app window this is textSecondary, and Increase Contrast makes it the primary text colour.
    readonly property color windowSecondary: increaseContrast ? colors.text : (windowSurface ? colors.windowTextSecondary : colors.textSecondary)

    // The dark palette for surfaces that are always dark (Apps), hooked like `colors`.
    readonly property var darkColors: devGlyphMode !== "" ? glyphColors(accentedDark) : accentedDark
    // The light palette for surfaces that are always light (the menu bar's dark foreground over a light wallpaper), hooked like `colors`.
    readonly property var lightColors: devGlyphMode !== "" ? glyphColors(accentedLight) : accentedLight
    // Highlight colour (text selection, Automatic as on macOS): it follows the accent.
    readonly property color highlight: colors.accent
    readonly property color highlightText: colors.accentText

    // Dev-only hook for tests/visual (contrast glyph mask; set by the shell's `visual glyphs <mode>` IPC, which is
    // refused outside GRASSFIELD_DEV; always "" in production). Every text and icon colour (text, textSecondary,
    // accentText) is replaced by a marker colour: "hidden" (fully transparent), "white" or "black" (opaque, one
    // unit off pure). withAlpha() leaves a marker colour alone, so label opacity tokens cannot undo it.
    // Material, outlines and shadows around text are unchanged.
    property string devGlyphMode: ""

    readonly property var glyphMarkers: ({hidden: "#00010203", white: "#fffffe", black: "#000001"})

    function glyphColors(base: var): var {
        const c = Object.assign({}, base);
        const m = glyphMarkers[devGlyphMode];
        c.text = m;
        c.textSecondary = m;
        c.accentText = m;
        c.selectionText = m;
        c.fieldText = m;
        c.barText = m;
        c.indicator = m;
        c.destructiveText = m;
        return c;
    }

    function isGlyphMarker(color: color): bool {
        const r = Math.round(color.r * 255);
        const g = Math.round(color.g * 255);
        const b = Math.round(color.b * 255);
        return (r === 1 && g === 2 && b === 3) || (r === 255 && g === 255 && b === 254) || (r === 0 && g === 0 && b === 1);
    }

    // First installed family of the token list (Qt has no per-font fallback list in QML).
    readonly property string fontFamily: Qt.fontFamilies().indexOf(Tokens.typographyFamily) !== -1 ? Tokens.typographyFamily : Tokens.typographyFallbackFamily
    readonly property var curve: Tokens.motionCurveStandard

    // Size-dependent tracking of Inter's "dynamic metrics" (the reference's optical tracking): em = a + b * e^(c * px),
    // returned in pixels for Text.font.letterSpacing. Larger text is set tighter, small text slightly looser.
    function tracking(pixelSize: real): real {
        return (Tokens.typographyTrackingA + Tokens.typographyTrackingB * Math.exp(Tokens.typographyTrackingC * pixelSize)) * pixelSize;
    }

    function clamp01(v: real): real {
        return Math.max(0, Math.min(1, v));
    }

    // Tint opacity of the material: 1 at transparency 0, tintAlphaMin at transparency 1, linear in between, except that the
    // A2 clamp keeps it at or above tintAlphaClamp up to transparency tintClampUntil (the default 0.25 is above it, so the
    // frosted default is unclamped). Past tintClampUntil it falls linearly from the clamp value to tintAlphaMin.
    function tintAlpha(t: real): real {
        const x = clamp01(t);
        const linear = 1 - x * (1 - Tokens.materialTintAlphaMin);
        const until = Tokens.materialTintClampUntil;
        if (x <= until)
            return Math.max(linear, Tokens.materialTintAlphaClamp);
        return Tokens.materialTintAlphaClamp + (Tokens.materialTintAlphaMin - Tokens.materialTintAlphaClamp) * (x - until) / (1 - until);
    }

    // Compositor blur follows the transparency (GF-125, docs/specs/ui.md "Material blur"): Hyprland carries one blur size and
    // pass count for every surface (ext-background-effect and layer rules take no per-surface strength), so the shell asks
    // for the value of the current transparency. Linear from blurSizeMin (0+) to blurSizeMax (1), 18 at the default 0.25.
    function blurSize(t: real): int {
        return Math.round(Tokens.materialBlurSizeMin + (Tokens.materialBlurSizeMax - Tokens.materialBlurSizeMin) * clamp01(t));
    }

    function blurPasses(t: real): int {
        return clamp01(t) < Tokens.materialBlurPassesFrom ? Tokens.materialBlurPassesLight : Tokens.materialBlurPassesFull;
    }

    // What the compositor is asked for now (Reduce Transparency: opaque surfaces request no blur; the minimum is kept).
    readonly property int compositorBlurSize: blurSize(effectiveTransparency)
    readonly property int compositorBlurPasses: blurPasses(effectiveTransparency)

    // Animation duration: Reduce Motion caps every animation at reducedMax (crossfade).
    function duration(ms: real): real {
        return reduceMotion ? Math.min(ms, Tokens.motionReducedMax) : ms;
    }

    function withAlpha(color: color, alpha: real): color {
        if (devGlyphMode !== "" && isGlyphMarker(color))
            return color;
        return Qt.alpha(color, alpha);
    }
}
