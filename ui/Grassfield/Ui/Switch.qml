import QtQuick
import QtQuick.Templates as T

// On/off switch (QtQuick.Templates Switch), the stock-Controls shaped sibling of Toggle: it toggles itself on a click, on
// Space, and by dragging the knob; `toggled()` reports a user change. Use Toggle where the host owns the value.
T.Switch {
    id: root

    property string accessibleName: ""

    implicitWidth: Tokens.controlToggleWidth
    implicitHeight: Tokens.controlToggleHeight
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.CheckBox
    Accessible.name: root.accessibleName !== "" ? root.accessibleName : root.text
    // A hidden or disabled control ignores every activation path, assistive technology included.
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.click()
    Accessible.onToggleAction: if (root.visible && root.enabled)
        root.click()

    // A hidden or disabled control that still holds the focus ignores its activation keys.
    Keys.onPressed: event => {
        if ((!root.visible || !root.enabled) && (ActivationKeys.activation(event.key)))
            event.accepted = true;
    }

    FocusGuard {}

    indicator: Item {
        width: root.width
        height: root.height
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: root.checked ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)

            Behavior on color {
                ColorAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }
        }

        Rectangle {
            readonly property real inset: (Tokens.controlToggleHeight - Tokens.controlToggleKnobHeight) / 2
            width: Tokens.controlToggleKnobWidth
            height: Tokens.controlToggleKnobHeight
            radius: height / 2
            y: inset
            x: inset + root.visualPosition * (root.width - width - 2 * inset)
            color: Appearance.colors.knob

            Behavior on x {
                enabled: !root.pressed
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curve
                }
            }
        }

        FocusRing {
            shapeRadius: height / 2
            visible: root.visualFocus
        }
    }

    // The track is the whole control: no label next to it.
    contentItem: Item {}
}
