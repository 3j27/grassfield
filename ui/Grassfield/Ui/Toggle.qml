import QtQuick
import QtQuick.Templates as T

// On/off switch on a QtQuick.Templates Control: the host owns the value. checked is set from outside; toggled() reports a user
// request to flip it (Space, Return, Enter, a click, an accessibility toggle). Switch is the self-toggling stock sibling.
T.Control {
    id: root

    property bool checked: false
    property string accessibleName: ""

    signal toggled(bool checked)

    implicitWidth: Tokens.controlToggleWidth
    implicitHeight: Tokens.controlToggleHeight
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.CheckBox
    Accessible.name: root.accessibleName
    Accessible.checkable: true
    Accessible.checked: root.checked
    Accessible.focusable: true
    // A hidden or disabled Toggle ignores every activation path, assistive technology included.
    Accessible.onToggleAction: if (root.visible && root.enabled)
        root.toggled(!root.checked)
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.toggled(!root.checked)

    Keys.onPressed: event => {
        if (!root.visible || !root.enabled) {
            if (ActivationKeys.activation(event.key))
                event.accepted = true;
            return;
        }
        if (ActivationKeys.activation(event.key)) {
            root.toggled(!root.checked);
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

        Behavior on color {
            ColorAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }
    }

    FocusGuard {}

    FocusRing {
        shapeRadius: root.height / 2
        visible: root.visualFocus
    }

    Rectangle {
        readonly property real inset: (Tokens.controlToggleHeight - Tokens.controlToggleKnobHeight) / 2
        width: Tokens.controlToggleKnobWidth
        height: Tokens.controlToggleKnobHeight
        radius: height / 2
        y: inset
        x: root.checked ? root.width - width - inset : inset
        color: Appearance.colors.knob

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
        cursorShape: Qt.ArrowCursor
        onClicked: {
            root.forceActiveFocus();
            root.toggled(!root.checked);
        }
    }
}
