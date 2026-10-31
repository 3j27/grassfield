import QtQuick
import QtQuick.Templates as T

// On/off switch (QtQuick.Templates Switch), the stock-Controls shaped sibling of Toggle: it toggles itself on a click, on
// Space, and by dragging the knob; `toggled()` reports a user change. Use Toggle where the host owns the value.
T.Switch {
    id: root

    property string accessibleName: ""
    // On, the track takes the selection colour, the fill of a checked box and a default button (ADR-0039 step 11, D-Q4); the
    // white knob is outlined in the fill's mark colour where it holds under 3:1 there (Accent.knobOutlined).
    readonly property bool knobOutlined: root.checked && Accent.knobOutlined(String(Appearance.colors.knob), String(Appearance.colors.selection), Tokens.controlKnobMinContrast)

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
            color: root.checked ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
            // Increase Contrast outlines the track, as the other controls: the off track alone is barely apart from its backdrop.
            border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

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
            // Increase Contrast outlines the knob too: white on a light track is 1.57:1 without it. On a fill where white holds
            // under 3:1, the fill's mark colour outlines it.
            border.width: Appearance.increaseContrast || root.knobOutlined ? Tokens.controlBorderWidth : 0
            border.color: root.knobOutlined ? Appearance.colors.selectionText : Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

            // Under Reduce Motion the knob jumps to its side (ADR-0039 step 5).
            Behavior on x {
                enabled: !root.pressed && !Appearance.reduceMotion
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
