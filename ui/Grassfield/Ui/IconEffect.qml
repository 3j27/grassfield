import QtQuick

// The icon appearance effect of one mode over an item (an Image or a layered Item): one custom fragment shader
// (shaders/icon.frag, built to icon.frag.qsb by scripts/dev/build-shaders.sh) that separates the icon's plate from its
// glyph and renders both for the mode. Used by TintedIcon and so by every icon surface and the mode previews in Settings.
// The numbers are the `iconMode` token group; the algorithm and its limits are in docs/specs/ui.md, "Icon shader".
ShaderEffect {
    id: root

    // The item whose texture is drawn (the effect takes its own texture of it: a hidden item still renders).
    property Item source: null
    property string mode: "default"
    property color tint: Appearance.iconTint
    property bool darkAppearance: Appearance.dark
    // Drawn over the bare wallpaper (desktop icons): a look that holds on any wallpaper brightness.
    property bool wallpaper: false
    // Nominal icon edge in logical pixels (the rim has a width in logical pixels).
    property real nominalSize: 48

    readonly property var params: IconModes.effect(root.mode, root.tint)

    // Shader uniforms (names match shaders/icon.frag).
    // A child item (not a bare property object) so that it lives in the same window as the effect; it is not drawn
    // itself (the effect draws its texture).
    ShaderEffectSource {
        id: textureSource
        visible: false
        sourceItem: root.source
        smooth: true
        mipmap: true
    }
    readonly property var iconTexture: textureSource
    readonly property real dark: root.darkAppearance ? 1 : 0
    readonly property real overWallpaper: root.wallpaper ? 1 : 0
    readonly property real clearPlateAlphaWallpaper: Tokens.iconModeClearPlateAlphaWallpaper
    // The rim keeps its width in logical pixels up to rimFullSize and shrinks and fades on smaller icons (a 1 px rim is
    // heavy on a 16 px icon).
    readonly property real sysPlateInset: Tokens.iconModeSysPlateInset
    readonly property real sysPlateRadius: Tokens.iconModeSysPlateRadius
    readonly property real sysGlyphScale: Tokens.iconModeSysGlyphScale
    readonly property real sizeFactor: Math.min(1, root.nominalSize / Tokens.iconModeRimFullSize)
    readonly property real rimGain: Math.max(Tokens.iconModeRimMinOpacity, root.sizeFactor)
    readonly property real rimUv: Math.max(Tokens.iconModeRimMinWidth, Tokens.iconModeRimWidth * root.sizeFactor) / Math.max(1, root.nominalSize)
    readonly property real plateToleranceLow: Tokens.iconModePlateToleranceLow
    readonly property real plateToleranceHigh: Tokens.iconModePlateToleranceHigh
    readonly property real plateAlphaLow: Tokens.iconModePlateAlphaLow
    readonly property real plateAlphaHigh: Tokens.iconModePlateAlphaHigh
    readonly property real darkPlateLuma: Tokens.iconModeDarkPlateLuma
    readonly property real darkPageLuma: Tokens.iconModeDarkPageLuma
    readonly property real darkChromaKeep: Tokens.iconModeDarkChromaKeep
    readonly property real darkGlyphLuma: Tokens.iconModeDarkGlyphLuma
    readonly property real darkGlyphBoost: Tokens.iconModeDarkGlyphBoost
    readonly property real darkGlyphFloor: Tokens.iconModeDarkGlyphFloor
    readonly property real darkRim: Tokens.iconModeDarkRim
    readonly property real clearPlateAlphaDark: Tokens.iconModeClearPlateAlphaDark
    readonly property real clearPlateAlphaLight: Tokens.iconModeClearPlateAlphaLight
    readonly property real clearInkDark: Tokens.iconModeClearInkDark
    readonly property real clearInkLight: Tokens.iconModeClearInkLight
    readonly property real clearDetail: Tokens.iconModeClearDetail
    readonly property real clearRim: Tokens.iconModeClearRim
    readonly property real tintedPlateScale: Tokens.iconModeTintedPlateScale
    readonly property real tintedPlateMixLight: Tokens.iconModeTintedPlateMixLight
    readonly property real tintedGlyphLift: Tokens.iconModeTintedGlyphLift
    readonly property real tintedGlyphShadeLight: Tokens.iconModeTintedGlyphShadeLight
    readonly property real tintedDetail: Tokens.iconModeTintedDetail
    readonly property real tintedRim: Tokens.iconModeTintedRim
    // 1 dark, 2 clear, 3 tinted (`tint` is the colour uniform).
    readonly property real modeIndex: root.params.index

    // The compiled shader; overridable for tests of the failure path.
    property url shaderUrl: Qt.resolvedUrl("shaders/icon.frag.qsb")
    fragmentShader: root.shaderUrl
    onStatusChanged: {
        if (root.status === ShaderEffect.Error)
            IconModes.warnOnce("icon shader failed to load, icons are drawn as they are: " + root.log);
    }
    blending: true
}
