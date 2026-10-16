pragma ComponentBehavior: Bound
import QtQuick

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

    // Diffused shadow: concentric 1 px rings with a smooth falloff, always outside the
    // shape (never under the glass).
    Repeater {
        model: root.shadowEnabled ? Tokens.shadowBlur : 0
        delegate: Rectangle {
            id: ring
            required property int index
            readonly property real grow: index + 1
            readonly property real falloff: 1 - grow / Tokens.shadowBlur
            readonly property real topGrow: Math.max(grow - Tokens.shadowOffsetY, 1)
            x: -grow
            y: -topGrow
            width: root.width + 2 * grow
            height: root.height + topGrow + grow + Tokens.shadowOffsetY
            radius: root.radius + grow
            color: "transparent"
            border.width: 1
            border.color: Appearance.withAlpha(Appearance.colors.shadow,
                Tokens.shadowOpacity * Math.pow(ring.falloff, 2.2) * (0.35 + 0.65 * root.tintAlpha))
        }
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
