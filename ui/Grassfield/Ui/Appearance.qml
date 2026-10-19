pragma Singleton
import QtQuick

// Appearance state shared by every Grassfield surface. The shell (or an app) feeds
// the user-facing settings in; surfaces only read the derived values below.
QtObject {
    // User settings (set by the host).
    property bool dark: true
    property real transparency: Tokens.materialDefaultTransparency
    property bool reduceTransparency: false
    property bool reduceMotion: false
    // Icon appearance (ADR-0014): default | dark | clear | tinted, and the tint setting ("accent" or "#rrggbb").
    property string iconMode: "default"
    property string iconTintSetting: "accent"
    // Folder colour (`icons.folderColor`): "theme" (the icon theme's own), "accent" or "#rrggbb".
    property string folderColorSetting: "theme"

    // Derived values.
    // Tint of the Tinted icon mode: the chosen colour, the accent by default.
    readonly property color iconTint: IconModes.tintColor(iconTintSetting, colors.accent)
    // Colour of folder icons for the global setting (the accent for "accent"); only meaningful when it recolours.
    readonly property color folderTint: FolderStyle.colorOf(folderColorSetting, colors.accent)
    // Reduce Transparency is equivalent to transparency 0 (opaque tinted surfaces).
    readonly property real effectiveTransparency: reduceTransparency ? 0 : clamp01(transparency)
    // Hairline alpha: the light appearance uses a lighter line (F1 gap 18).
    readonly property real separatorOpacity: dark ? Tokens.materialSeparatorOpacity : Tokens.materialSeparatorOpacityLight
    readonly property var colors: devGlyphMode !== "" ? glyphColors(baseColors) : baseColors
    readonly property var baseColors: dark ? Tokens.colorDark : Tokens.colorLight
    // The dark palette for surfaces that are always dark (Apps), hooked like `colors`.
    readonly property var darkColors: devGlyphMode !== "" ? glyphColors(Tokens.colorDark) : Tokens.colorDark
    // The light palette for surfaces that are always light (the menu bar's dark foreground over a light wallpaper), hooked like `colors`.
    readonly property var lightColors: devGlyphMode !== "" ? glyphColors(Tokens.colorLight) : Tokens.colorLight

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
        c.fieldText = m;
        c.barText = m;
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
