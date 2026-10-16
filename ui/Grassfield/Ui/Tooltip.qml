import QtQuick

// Small label on the frosted material. The host positions it; show/hide fades it.
// `shown` is the desired state; it appears after `delay` ms and hides immediately.
Item {
    id: root

    property string text: ""
    property bool shown: false
    property int delay: Tokens.controlTooltipDelay

    readonly property bool visibleNow: root.shown && (delay <= 0 || delayTimer.fired)

    implicitWidth: label.implicitWidth + 2 * Tokens.controlTooltipPadding * 1.5
    implicitHeight: label.implicitHeight + 2 * Tokens.controlTooltipPadding
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

    Material {
        anchors.fill: parent
        radius: Tokens.radiusTooltip
        highlightEnabled: false
        shadowEnabled: false
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }
}
