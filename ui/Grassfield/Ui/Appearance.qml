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

    // Derived values.
    // Reduce Transparency is equivalent to transparency 0 (opaque tinted surfaces).
    readonly property real effectiveTransparency: reduceTransparency ? 0 : clamp01(transparency)
    readonly property var colors: dark ? Tokens.colorDark : Tokens.colorLight
    // First installed family of the token list (Qt has no per-font fallback list in QML).
    readonly property string fontFamily: Qt.fontFamilies().indexOf(Tokens.typographyFamily) !== -1 ? Tokens.typographyFamily : Tokens.typographyFallbackFamily
    readonly property var curve: Tokens.motionCurveStandard

    function clamp01(v: real): real {
        return Math.max(0, Math.min(1, v));
    }

    // Tint opacity of the material: 1 at transparency 0, tintAlphaMin at transparency 1.
    function tintAlpha(t: real): real {
        return 1 - clamp01(t) * (1 - Tokens.materialTintAlphaMin);
    }

    // Animation duration: Reduce Motion caps every animation at reducedMax (crossfade).
    function duration(ms: real): real {
        return reduceMotion ? Math.min(ms, Tokens.motionReducedMax) : ms;
    }

    function withAlpha(color: color, alpha: real): color {
        return Qt.alpha(color, alpha);
    }
}
