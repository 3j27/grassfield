pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// Glass surface (master-prompt 5.5, ADR-0024): the tint, a diffused shadow drawn outside the shape, and the macOS glass
// edge: one device pixel of darker edge outside, one of brighter specular rim inside (stronger along the top).
//
// This item does NOT blur. Blur comes from the compositor: the hosting window must
// declare this item's geometry as its blur region, e.g.
//     BackgroundEffect.blurRegion: Region { item: material; radius: material.radius }
// and only while material.blurActive is true.
Item {
    id: root

    // 0 = opaque, 1 = most transparent. Defaults to the global appearance value.
    property real transparency: Appearance.effectiveTransparency
    property real radius: Tokens.radiusDock
    property bool shadowEnabled: true
    property bool highlightEnabled: true
    property bool borderEnabled: true

    // Host contract: request a blur region only when the surface is not opaque.
    readonly property bool blurActive: transparency > 0
    // Surfaces without text (the Dock shelf) may be more translucent than the A2 clamp allows: an explicit tint alpha
    // (0..1, -1 = from `transparency`) that applies only while the surface is not opaque (Reduce Transparency wins).
    property real tintAlphaOverride: -1
    // Glass class (ADR-0024 section 2): "menu", "notification", "controls" or "apps" take the class tint, raised to keep
    // the text legible over the backdrop the shell knows for this output (Appearance.glassAlpha); "" keeps the one material
    // tint (Appearance.tintAlpha).
    property string glassClass: ""
    // The luminance range {lumMin, lumMax} behind this surface when its host measured it itself (the menu bar's strip); null: the
    // output's backdrop (Appearance.glassAlpha).
    property var backdropOverride: null
    // The output this surface is shown on (the Screen attached property of its window).
    readonly property string screenName: Screen.name
    // Where the surface lies on that output (output px), for the backdrop under it (G-3 per surface, Appearance.glassAlpha):
    // a host whose window does not cover the output, or whose surface moves without moving itself (a card in a list), sets
    // the area to judge; empty: measured here when the window covers the output (its coordinates are the output's), unknown
    // otherwise (the whole output's range).
    property rect backdropRect: Qt.rect(0, 0, 0, 0)
    property rect measuredRect: Qt.rect(0, 0, 0, 0)
    readonly property rect glassRect: backdropRect.width > 0 ? backdropRect : measuredRect

    function measureRect(): void {
        const w = root.Window.window;
        if (!w || !root.visible || w.width < Screen.width || w.height < Screen.height || root.width <= 0) {
            root.measuredRect = Qt.rect(0, 0, 0, 0);
            return;
        }
        const p = root.mapToItem(null, 0, 0);
        root.measuredRect = Qt.rect(p.x, p.y, root.width, root.height);
    }

    onVisibleChanged: Qt.callLater(root.measureRect)
    onXChanged: Qt.callLater(root.measureRect)
    onYChanged: Qt.callLater(root.measureRect)
    onWidthChanged: Qt.callLater(root.measureRect)
    onHeightChanged: Qt.callLater(root.measureRect)
    Component.onCompleted: Qt.callLater(root.measureRect)
    // Rims (default: the material tokens): the inner specular rim (highlight) and the outer edge (border), each one device
    // pixel wide at every scale. The outer edge is dark in both appearances, the inner rim light.
    property real highlightOpacity: Appearance.dark ? Tokens.materialHighlightOpacity : Tokens.materialHighlightOpacityLight
    property real borderOpacity: Appearance.dark ? Math.max(Tokens.materialEdgeOpacityDark, Tokens.materialBorderOpacity) : Tokens.materialBorderOpacity
    property color borderColor: Appearance.dark ? Appearance.colors.shadow : Appearance.colors.materialBorder
    readonly property real hairline: 1 / Math.max(1, Screen.devicePixelRatio)
    readonly property real baseTintAlpha: tintAlphaOverride >= 0 && blurActive ? tintAlphaOverride : (glassClass !== "" ? (backdropOverride ? Appearance.glassAlphaOver(glassClass, transparency, backdropOverride) : Appearance.glassAlpha(glassClass, transparency, screenName, glassRect)) : Appearance.tintAlpha(transparency))
    // Increase Contrast frosts every glass surface (ADR-0024 G-8); Reduce Transparency has already made it opaque.
    readonly property real tintAlpha: Appearance.increaseContrast ? Math.max(Tokens.glassContrastFrost, baseTintAlpha) : baseTintAlpha
    // The host window needs this much room around the shape for the shadow.
    readonly property int shadowMargin: Tokens.shadowBlur + Tokens.shadowOffsetY

    default property alias content: contentItem.data

    // Diffused gaussian shadow (RectangularShadow, Qt 6.9+), masked so that it never shows
    // under the glass: the shape is cut out of the shadow layer.
    Item {
        id: shadowSource
        visible: false
        layer.enabled: root.shadowEnabled
        x: -root.shadowMargin
        y: -root.shadowMargin
        width: root.width + 2 * root.shadowMargin
        height: root.height + 2 * root.shadowMargin

        RectangularShadow {
            x: root.shadowMargin
            y: root.shadowMargin
            width: root.width
            height: root.height
            radius: root.radius
            blur: Tokens.shadowBlur
            offset: Qt.vector2d(0, Tokens.shadowOffsetY)
            color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity * (0.35 + 0.65 * root.tintAlpha))
        }
    }

    Item {
        id: shadowCutout
        visible: false
        layer.enabled: root.shadowEnabled
        x: shadowSource.x
        y: shadowSource.y
        width: shadowSource.width
        height: shadowSource.height

        Rectangle {
            x: root.shadowMargin
            y: root.shadowMargin
            width: root.width
            height: root.height
            radius: root.radius
            color: "black"
        }
    }

    MultiEffect {
        visible: root.shadowEnabled
        x: shadowSource.x
        y: shadowSource.y
        width: shadowSource.width
        height: shadowSource.height
        source: shadowSource
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: shadowCutout
        maskInverted: true
    }

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: Appearance.withAlpha(Appearance.colors.materialTint, root.tintAlpha)
    }

    // Inner specular rim: one device pixel inside the edge, half strength all round and full strength along the straight
    // part of the top edge (the light comes from above).
    Rectangle {
        visible: root.highlightEnabled
        anchors.fill: parent
        anchors.margins: root.hairline
        radius: Math.max(0, root.radius - root.hairline)
        color: "transparent"
        border.width: root.hairline
        border.color: Appearance.withAlpha(Appearance.colors.materialHighlight, root.highlightOpacity / 2)
    }

    Rectangle {
        visible: root.highlightEnabled
        x: root.radius
        y: root.hairline
        width: Math.max(0, root.width - 2 * root.radius)
        height: root.hairline
        color: Appearance.withAlpha(Appearance.colors.materialHighlight, root.highlightOpacity)
    }

    // Outer edge: one device pixel.
    Rectangle {
        visible: root.borderEnabled
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: root.hairline
        border.color: Appearance.withAlpha(root.borderColor, root.borderOpacity)
    }

    Item {
        id: contentItem
        anchors.fill: parent
    }
}
