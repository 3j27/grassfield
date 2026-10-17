import QtQuick
import Grassfield.Ui

// Keyboard-reachable control (CC9): Tab and Up/Down move between controls, Space/Return activate,
// Left/Right report arrow(direction). Draws the focus ring; content is added by the user.
Item {
    id: root

    property string accessibleName: ""
    property bool checkable: false
    property bool checked: false
    property real ringRadius: Tokens.radiusControl

    signal activated
    signal arrow(int direction)

    activeFocusOnTab: true
    Accessible.role: checkable ? Accessible.CheckBox : Accessible.Button
    Accessible.name: accessibleName
    Accessible.focusable: true
    Accessible.checkable: checkable
    Accessible.checked: checked
    Accessible.onPressAction: root.activated()

    function moveFocus(forward: bool): void {
        const next = nextItemInFocusChain(forward);
        if (next)
            next.forceActiveFocus();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activated();
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            root.moveFocus(true);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up) {
            root.moveFocus(false);
            event.accepted = true;
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            root.arrow(event.key === Qt.Key_Right ? 1 : -1);
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        z: 10
        radius: root.ringRadius
        color: "transparent"
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.text
    }
}
