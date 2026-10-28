import QtQuick
import Grassfield.Ui

// The (i) button at the end of a list row (macOS 27 Bluetooth's devices): a ringed "i" in the secondary colour; Space, Return
// or a click asks for the row's details (clicked).
Item {
    id: root

    property string accessibleName: ""
    // The ring shows for the keyboard's focus only, as a control's visualFocus: a click focuses the button without it.
    property bool clickFocused: false
    readonly property bool visualFocus: root.activeFocus && !root.clickFocused

    signal clicked

    implicitWidth: Tokens.settingsInfoSize
    implicitHeight: Tokens.settingsInfoSize
    activeFocusOnTab: true
    onActiveFocusChanged: if (!root.activeFocus)
        root.clickFocused = false
    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.focusable: true
    Accessible.onPressAction: root.clicked()

    Keys.onPressed: event => {
        if (ActivationKeys.activation(event.key)) {
            root.clicked();
            event.accepted = true;
        }
    }

    Icon {
        anchors.centerIn: parent
        name: "info"
        size: Tokens.settingsInfoSize
        color: mouse.pressed ? Appearance.colors.text : Appearance.windowSecondary
    }

    FocusRing {
        shapeRadius: root.width / 2
        visible: root.visualFocus
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        onClicked: {
            root.clickFocused = true;
            root.forceActiveFocus();
            root.clicked();
        }
    }
}
