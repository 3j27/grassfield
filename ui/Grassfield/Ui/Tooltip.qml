import QtQuick
import QtQuick.Shapes

// Small label capsule on the frosted material. The host positions it; show/hide fades it.
// `shown` is the desired state; it appears after `delay` ms and hides immediately.
// With `tail` a small pointer hangs below the capsule (the Dock label); the item's height then includes it. `tailSide`
// "left" or "right" puts the pointer on that side of the capsule instead (a label beside the tile of a Dock on the left
// or right edge); the item's width then includes it.
Item {
    id: root

    property string text: ""
    property bool shown: false
    property int delay: Tokens.controlTooltipDelay
    property bool tail: false
    property string tailSide: "bottom"
    readonly property bool sideTail: root.tail && (root.tailSide === "left" || root.tailSide === "right")

    readonly property bool visibleNow: root.shown && (delay <= 0 || delayTimer.fired)
    readonly property real tailHeight: root.tail && !root.sideTail ? Tokens.controlTooltipTailHeight : 0
    readonly property real tailExtent: root.sideTail ? Tokens.controlTooltipTailHeight : 0

    // Whole device pixels for the capsule, so that a tail meets its edge exactly (no gap, no overlap).
    readonly property real pixelRatio: Math.max(1, Screen.devicePixelRatio)

    implicitWidth: capsule.width + root.tailExtent
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
        x: root.sideTail && root.tailSide === "left" ? root.tailExtent : 0
        width: Math.ceil((label.implicitWidth + 2 * Tokens.controlTooltipPaddingX) * root.pixelRatio) / root.pixelRatio
        height: Math.ceil((label.implicitHeight + 2 * Tokens.controlTooltipPaddingY) * root.pixelRatio) / root.pixelRatio

        // A text surface: the menus' class (ADR-0039 step 22).
        Material {
            id: glass
            glassClass: "menu"
            anchors.fill: parent
            radius: height / 2
            highlightEnabled: false
            shadowEnabled: false
            // With a tail, capsule and tail are one silhouette: an edge round the capsule alone would cross the joint.
            borderEnabled: !root.tail
        }

        Text {
            textFormat: Text.PlainText
            id: label
            anchors.centerIn: parent
            text: root.text
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
            font.weight: Tokens.typographyMenuWeight
        }
    }

    // Tail: a downward triangle in the capsule's glass, from the capsule's edge (a device-pixel line, so no seam shows): it
    // does not overlap the translucent capsule, whose tint would show twice there (UI audit 2026-11-05, LOW).
    Shape {
        visible: root.tail && !root.sideTail
        x: Math.round((root.width - Tokens.controlTooltipTailWidth) / 2 * root.pixelRatio) / root.pixelRatio
        y: capsule.height
        width: Tokens.controlTooltipTailWidth
        height: Tokens.controlTooltipTailHeight
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeWidth: 0
            fillColor: glass.fillColor // the capsule's own glass (ADR-0039 step 22)
            startX: 0
            startY: 0
            PathLine {
                x: Tokens.controlTooltipTailWidth
                y: 0
            }
            PathLine {
                x: Tokens.controlTooltipTailWidth / 2
                y: Tokens.controlTooltipTailHeight
            }
            PathLine {
                x: 0
                y: 0
            }
        }
    }

    // Side tail: a triangle pointing left or right, from the capsule's edge, as the bottom one.
    Shape {
        visible: root.sideTail
        x: root.tailSide === "left" ? 0 : capsule.width
        y: Math.round((capsule.height - Tokens.controlTooltipTailWidth) / 2 * root.pixelRatio) / root.pixelRatio
        width: Tokens.controlTooltipTailHeight
        height: Tokens.controlTooltipTailWidth
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeWidth: 0
            fillColor: glass.fillColor // the capsule's own glass (ADR-0039 step 22)
            startX: root.tailSide === "left" ? Tokens.controlTooltipTailHeight : 0
            startY: 0
            PathLine {
                x: root.tailSide === "left" ? Tokens.controlTooltipTailHeight : 0
                y: Tokens.controlTooltipTailWidth
            }
            PathLine {
                x: root.tailSide === "left" ? 0 : Tokens.controlTooltipTailHeight
                y: Tokens.controlTooltipTailWidth / 2
            }
            PathLine {
                x: root.tailSide === "left" ? Tokens.controlTooltipTailHeight : 0
                y: 0
            }
        }
    }
}
