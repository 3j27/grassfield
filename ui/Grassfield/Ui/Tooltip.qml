import QtQuick
import QtQuick.Shapes

// Small label capsule on the frosted material. The host positions it; show/hide fades it.
// `shown` is the desired state; it appears after `delay` ms and hides immediately.
// With `tail` a small pointer hangs below the capsule (the Dock label); the item's height then includes it.
Item {
    id: root

    property string text: ""
    property bool shown: false
    property int delay: Tokens.controlTooltipDelay
    property bool tail: false

    readonly property bool visibleNow: root.shown && (delay <= 0 || delayTimer.fired)
    readonly property real tailHeight: root.tail ? Tokens.controlTooltipTailHeight : 0

    implicitWidth: label.implicitWidth + 2 * Tokens.controlTooltipPaddingX
    implicitHeight: capsule.height + root.tailHeight
    width: implicitWidth
    height: implicitHeight
    opacity: visibleNow ? 1 : 0
    visible: opacity > 0
    Accessible.role: Accessible.ToolTip
    Accessible.name: root.text

    onShownChanged: {
        delayTimer.fired = false;
        if (shown && delay > 0)
            delayTimer.restart();
        else
            delayTimer.stop();
    }

    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionFast)
        }
    }

    Timer {
        id: delayTimer
        property bool fired: false
        interval: root.delay
        onTriggered: fired = true
    }

    Item {
        id: capsule
        width: parent.width
        height: label.implicitHeight + 2 * Tokens.controlTooltipPaddingY

        Material {
            anchors.fill: parent
            radius: height / 2
            highlightEnabled: false
            shadowEnabled: false
        }

        Text {
            textFormat: Text.PlainText
            id: label
            anchors.centerIn: parent
            text: root.text
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.weight: Tokens.typographyMenuWeight
        }
    }

    // Tail: a downward triangle in the material tint, overlapping the capsule by a pixel so that no seam shows.
    Shape {
        visible: root.tail
        x: (root.width - Tokens.controlTooltipTailWidth) / 2
        y: capsule.height - 1
        width: Tokens.controlTooltipTailWidth
        height: Tokens.controlTooltipTailHeight + 1
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeWidth: 0
            fillColor: Appearance.withAlpha(Appearance.colors.materialTint, Appearance.tintAlpha(Appearance.effectiveTransparency))
            startX: 0
            startY: 0
            PathLine {
                x: Tokens.controlTooltipTailWidth
                y: 0
            }
            PathLine {
                x: Tokens.controlTooltipTailWidth / 2
                y: Tokens.controlTooltipTailHeight + 1
            }
            PathLine {
                x: 0
                y: 0
            }
        }
    }
}
