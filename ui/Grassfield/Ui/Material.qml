pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// "Restrained glass" surface (master-prompt 5.5): high-opacity tint, subtle top
// highlight, 1 px inner border and a diffused shadow drawn outside the shape.
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
    readonly property real tintAlpha: Appearance.tintAlpha(transparency)
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

    // Top highlight: a gradient fading out within the top spacingMd pixels.
    Rectangle {
        visible: root.highlightEnabled
        anchors.fill: parent
        radius: root.radius
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Appearance.withAlpha(Appearance.colors.materialHighlight, Tokens.materialHighlightOpacity)
            }
            GradientStop {
                position: Math.min(1, Tokens.spacingMd / Math.max(root.height, 1))
                color: Appearance.withAlpha(Appearance.colors.materialHighlight, 0)
            }
            GradientStop {
                position: 1.0
                color: Appearance.withAlpha(Appearance.colors.materialHighlight, 0)
            }
        }
    }

    // 1 px inner border.
    Rectangle {
        visible: root.borderEnabled
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: 1
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
    }

    Item {
        id: contentItem
        anchors.fill: parent
    }
}
