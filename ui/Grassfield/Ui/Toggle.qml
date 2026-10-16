import QtQuick

// On/off switch. checked is set from outside; toggled() reports a user request to flip it.
Item {
    id: root

    property bool checked: false
    property string accessibleName: ""

    signal toggled(bool checked)

    implicitWidth: Tokens.controlToggleWidth
    implicitHeight: Tokens.controlToggleHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.CheckBox
    Accessible.name: root.accessibleName
    Accessible.checkable: true
    Accessible.checked: root.checked
    Accessible.focusable: true
    Accessible.onToggleAction: root.toggled(!root.checked)
    Accessible.onPressAction: root.toggled(!root.checked)

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.toggled(!root.checked);
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.text

        Behavior on color {
            ColorAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }
    }

    Rectangle {
        readonly property real inset: (Tokens.controlToggleHeight - Tokens.controlToggleKnob) / 2
        width: Tokens.controlToggleKnob
        height: Tokens.controlToggleKnob
        radius: width / 2
        y: inset
        x: root.checked ? root.width - width - inset : inset
        color: "#FFFFFF"

        Behavior on x {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionFast)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.toggled(!root.checked);
        }
    }
}
