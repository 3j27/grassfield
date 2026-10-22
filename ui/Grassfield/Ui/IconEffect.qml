import QtQuick

// The icon appearance effect of one mode over an item (an Image or a layered Item): one custom fragment shader
// (shaders/icon.frag, built to icon.frag.qsb by scripts/dev/build-shaders.sh), a single pass: the icon scaled onto a system
// plate (graphite, glass or tinted) and recoloured by a fixed transform per mode, no analysis of the icon. Used by
// TintedIcon and so by every icon surface and the mode previews in Settings.
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
    // Drawn over the accent fill of a selected row: 0 no, 1 a bright accent, 2 a dark one (the plate and the ink are the opposite of it).
    property real accentFill: 0
    // The folder colour step (FolderIcon): the artwork is recoloured in the shader, before the system plate is drawn,
    // so the plate and its rim keep their look. Not used when "recolor" is false.
    property bool recolor: false
    property color recolorTint: "#000000"
    // Nominal icon edge in logical pixels (the rim has a width in logical pixels).
    property real nominalSize: 48

    readonly property var params: IconModes.effect(root.mode, root.tint)

    // Shader uniforms (names match shaders/icon.frag).
    // The effect samples the Image's own texture (its texture provider, mipmapped by the Image): no offscreen pass per icon. The
    // hidden Image still gets its texture, because an effect that uses an item as a source keeps it rendered.
    readonly property var iconTexture: root.source
    readonly property real dark: root.darkAppearance ? 1 : 0
    // Over the bare wallpaper (desktop icons); for Clear also over a material that lets so much of it through (transparency at its
    // end) that the icon is over the wallpaper: the look that holds on any wallpaper brightness.
    readonly property real overWallpaper: (root.wallpaper || (root.params.index === 2 && root.accentFill < 0.5 && Appearance.effectiveTransparency >= Tokens.iconModeWallpaperLikeTransparency)) ? 1 : 0
    readonly property real clearPlateAlphaWallpaper: Tokens.iconModeClearPlateAlphaWallpaper
    readonly property real sysPlateInset: Tokens.iconModeSysPlateInset
    readonly property real sysPlateRadius: Tokens.iconModeSysPlateRadius
    readonly property real sysGlyphScale: Tokens.iconModeSysGlyphScale
    // The rim keeps its width in logical pixels up to rimFullSize and shrinks and fades on smaller icons (a 1 px rim is
    // heavy on a 16 px icon).
    readonly property real sizeFactor: Math.min(1, root.nominalSize / Tokens.iconModeRimFullSize)
    readonly property real rimGain: Math.max(Tokens.iconModeRimMinOpacity, root.sizeFactor)
    readonly property real rimUv: Math.max(Tokens.iconModeRimMinWidth, Tokens.iconModeRimWidth * root.sizeFactor) / Math.max(1, root.nominalSize)
    readonly property real darkPlateLuma: Tokens.iconModeDarkPlateLuma
    readonly property real darkArtSaturation: Tokens.iconModeDarkArtSaturation
    readonly property real darkArtScale: Tokens.iconModeDarkArtScale
    readonly property real darkArtLift: Tokens.iconModeDarkArtLift
    readonly property real darkRim: Tokens.iconModeDarkRim
    readonly property real rimInner: Tokens.iconModeRimInner
    readonly property real darkRimLight: Tokens.iconModeDarkRimLight
    readonly property real tintedRimMixDark: Tokens.iconModeTintedRimMixDark
    readonly property real tintedRimShadeLight: Tokens.iconModeTintedRimShadeLight
    readonly property real clearPlateAlphaDark: Tokens.iconModeClearPlateAlphaDark
    readonly property real clearPlateAlphaLight: Tokens.iconModeClearPlateAlphaLight
    readonly property real clearInkDark: Tokens.iconModeClearInkDark
    readonly property real clearInkLight: Tokens.iconModeClearInkLight
    readonly property real clearBackdropDark: Tokens.iconModeClearBackdropDark
    readonly property real clearBackdropLight: Tokens.iconModeClearBackdropLight
    readonly property real clearBackdropMid: Tokens.iconModeClearBackdropMid
    readonly property real clearInkFloor: Tokens.iconModeClearInkFloor
    readonly property real clearPlateAlphaAccent: Tokens.iconModeClearPlateAlphaAccent
    readonly property real clearRim: Tokens.iconModeClearRim
    readonly property real tintedPlateScale: Tokens.iconModeTintedPlateScale
    readonly property real tintedPlateMixLight: Tokens.iconModeTintedPlateMixLight
    readonly property real tintedRampLowDark: Tokens.iconModeTintedRampLowDark
    readonly property real tintedRampHighDark: Tokens.iconModeTintedRampHighDark
    readonly property real tintedRampLowLight: Tokens.iconModeTintedRampLowLight
    readonly property real tintedRampHighLight: Tokens.iconModeTintedRampHighLight
    readonly property real tintedRim: Tokens.iconModeTintedRim
    readonly property color folderTint: Qt.rgba(root.recolorTint.r, root.recolorTint.g, root.recolorTint.b, root.recolor ? 1 : 0)
    readonly property real folderBrightness: Tokens.folderIconBrightness
    readonly property real folderContrast: Tokens.folderIconContrast
    readonly property real folderColorization: Tokens.folderIconColorization
    readonly property real folderSaturation: Tokens.folderIconSaturation
    // 1 dark, 2 clear, 3 tinted (`tint` is the colour uniform).
    readonly property real modeIndex: root.params.index

    // The compiled shader; overridable for tests of the failure path.
    property url shaderUrl: Qt.resolvedUrl("shaders/icon.frag.qsb")
    fragmentShader: root.shaderUrl
    // The shader failed to load or compile: the owner draws the plain icon instead.
    readonly property bool failed: root.status === ShaderEffect.Error
    onFailedChanged: {
        if (root.failed) {
            Appearance.iconShaderBroken = true;
            IconModes.warnOnce("icon shader failed to load, icons are drawn as they are: " + root.log);
        }
    }
    blending: true
}
