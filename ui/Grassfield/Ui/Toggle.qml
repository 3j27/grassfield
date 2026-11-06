import QtQuick
import QtQuick.Effects
import QtQuick.Templates as T

// On/off switch on a QtQuick.Templates Control: the host owns the value. checked is set from outside; toggled() reports a user
// request to flip it (Space, Return, Enter, a click, an accessibility toggle). Switch is the self-toggling stock sibling.
T.Control {
    id: root

    property bool checked: false
    property string accessibleName: ""
    // The large switch of a pane's header row (macOS 27 Wi-Fi, Bluetooth): a 44 x 20 track, a 26 x 16 knob.
    property bool large: false

    signal toggled(bool checked)

    implicitWidth: root.large ? Tokens.controlToggleLargeWidth : Tokens.controlToggleWidth
    implicitHeight: root.large ? Tokens.controlToggleLargeHeight : Tokens.controlToggleHeight
    // Disabled on its own, as macOS draws a switch that cannot be changed: the track stays (an off switch remains visible,
    // on white too), the knob fades, and the accent when on. Inside a disabled container drawn dimmed (Settings' blocked page),
    // the container dims it once already (Appearance.dimsDisabled, UI audit 2026-11-05 U18).
    readonly property bool dimmed: Appearance.dimsDisabled(root)
    // On, the track takes the selection colour, the fill of a checked box and a default button (ADR-0039 step 11, D-Q4); the
    // white knob is outlined in the fill's mark colour where it holds under 3:1 there (Accent.knobOutlined).
    // The accent only while the window looks key, inside an app window (Appearance.accentShown, UI audit 2026-11-05 U17).
    readonly property bool keyLook: Appearance.accentShown(root.Window.window, root.Window.active)
    readonly property bool knobOutlined: root.checked && root.keyLook && Accent.knobOutlined(String(Appearance.colors.knob), String(Appearance.colors.selection), Tokens.controlKnobMinContrast)
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

    // Off, light: black at control.toggleOffTrackOpacity, as macOS 27 (UI audit 2026-11-05 U35).
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? (root.keyLook ? Appearance.withAlpha(Appearance.colors.selection, root.dimmed ? Tokens.materialDisabledOpacity : 1)
                                            : Appearance.withAlpha(Appearance.colors.fill, Appearance.inactiveFillOpacity * (root.dimmed ? Tokens.materialDisabledOpacity : 1)))
                            : Appearance.withAlpha(Appearance.colors.fill, Appearance.dark ? Appearance.fillOpacity : Tokens.controlToggleOffTrackOpacity)
        // Increase Contrast outlines the track, as the other controls: the off track alone is barely apart from its backdrop.
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

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
        readonly property real inset: (root.height - height) / 2
        width: root.large ? Tokens.controlToggleLargeKnobWidth : Tokens.controlToggleKnobWidth
        height: root.large ? Tokens.controlToggleLargeKnobHeight : Tokens.controlToggleKnobHeight
        radius: height / 2
        y: inset
        x: root.checked ? root.width - width - inset : inset
        color: Appearance.colors.knob
        // Increase Contrast outlines the knob too: white on a light track is 1.57:1 without it. On a fill where white holds
        // under 3:1, the fill's mark colour outlines it.
        border.width: Appearance.increaseContrast || root.knobOutlined ? Tokens.controlBorderWidth : 0
        border.color: root.knobOutlined ? Appearance.colors.selectionText : Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        opacity: root.dimmed ? Tokens.controlToggleDisabledKnobOpacity : 1

        // The knob's soft drop shadow, which sets it apart from a light off track (macOS 27, measured: ADR-0039 step 28, G9 with
        // Increase Contrast off): drawn under the knob (z -1) and faded with it.
        RectangularShadow {
            anchors.fill: parent
            z: -1
            radius: parent.radius
            blur: Tokens.controlKnobShadowBlur
            offset: Qt.vector2d(0, Tokens.controlKnobShadowOffsetY)
            color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.controlKnobShadowOpacity)
        }

        // Under Reduce Motion the knob jumps to its side; the track's colour still crossfades (ADR-0039 step 5).
        Behavior on x {
            enabled: !Appearance.reduceMotion
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
