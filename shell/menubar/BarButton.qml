import QtQuick
import Grassfield.Ui

// Menu bar item: hover/pressed highlight (also while its popup is open), keyboard focusable.
Item {
    id: root

    property string accessibleName: ""
    property bool active: false
    default property alias content: row.data
    readonly property bool hovered: hover.hovered

    signal activated
    signal scrolled(real delta)

    implicitWidth: row.implicitWidth + 2 * Tokens.spacingSm
    implicitHeight: Tokens.menubarHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.focusable: true
    Accessible.onPressAction: root.activated()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
            root.activated();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors {
            fill: parent
            topMargin: 1
            bottomMargin: 2
        }
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.hover, root.active ? Tokens.materialHoverOpacity * 1.5 : Tokens.materialHoverOpacity)
        opacity: root.hovered || root.active ? 1 : 0
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.accent

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }
    }

    // Focus ring stays visible even without hover.
    Rectangle {
        anchors {
            fill: parent
            topMargin: 1
            bottomMargin: 2
        }
        radius: Tokens.radiusControl
        color: "transparent"
        visible: root.activeFocus
        border.width: Tokens.controlFocusRing
        border.color: Appearance.colors.accent
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Tokens.spacingXs
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.ArrowCursor
    }

    TapHandler {
        onTapped: {
            root.forceActiveFocus();
            root.activated();
        }
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => root.scrolled(event.angleDelta.y)
    }
}
