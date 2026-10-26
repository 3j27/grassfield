import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// Keyboard-reachable control (CC9): Tab follows the grid rows; Up/Down are not handled here, they bubble to the
// host (ControlCenter), which moves focus to the module above or below; Left/Right move to the control beside
// this one (or, with handlesArrow, report arrow(direction) and the host of the control decides); Space activates,
// Return too (or confirmed() when returnActivates is false). Draws the focus ring for keyboard focus only (visualFocus,
// as the shared controls: never after a click); content is added by the user. A Templates Control for visualFocus: hosts
// that move focus for a key pass Qt.TabFocusReason.
T.Control {
    id: root

    property string accessibleName: ""
    property bool checkable: false
    property bool checked: false
    property real ringRadius: Tokens.radiusControl

    // Return/Enter activate like Space; false: they emit confirmed() instead (a capsule that expands).
    property bool returnActivates: true
    // True: Left/Right emit arrow(direction) instead of moving to the neighbouring control.
    property bool handlesArrow: false

    signal activated
    signal confirmed
    signal arrow(int direction)

    activeFocusOnTab: true
    Accessible.role: checkable ? Accessible.CheckBox : Accessible.Button
    Accessible.name: accessibleName
    Accessible.focusable: true
    Accessible.checkable: checkable
    Accessible.checked: checked
    Accessible.onPressAction: root.activated()

    // Untyped parent: the host is found by duck typing (it offers gridNavigate).
    function parentOf(item: var): var {
        return item.parent;
    }

    // Moves focus to the control beside (dx) or above/below (dy) this one: the nearest ancestor that offers
    // gridNavigate(item, dx, dy) decides. Returns false when there is none (or nothing in that direction).
    function navigate(dx: int, dy: int): bool {
        let p = parentOf(root);
        while (p && typeof p.gridNavigate !== "function")
            p = parentOf(p);
        return p ? p.gridNavigate(root, dx, dy) : false;
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || (root.returnActivates && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter))) {
            root.activated();
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.confirmed();
            event.accepted = true;
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            const direction = event.key === Qt.Key_Right ? 1 : -1;
            if (root.handlesArrow) {
                root.arrow(direction);
                event.accepted = true;
            } else {
                event.accepted = root.navigate(direction, 0);
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        z: 10
        radius: root.ringRadius
        color: "transparent"
        border.width: root.visualFocus ? Tokens.controlFocusOutline : 0
        border.color: Appearance.focusRingColor
    }
}
