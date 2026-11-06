pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Templates as T

// Segmented choice of 2-4 options (QtQuick.Templates Control + one AbstractButton per segment): a light track with the
// selected segment as a raised pill and ordinary text (macOS 27; the accent marks selection in lists and menus only). model: [{id, text}];
// value is the selected id (the host owns it: the control only reports `picked(id)`); Left/Right/Up/Down step through the
// segments. Each segment is a RadioButton for assistive technology.
T.Control {
    id: root

    property var model: []
    property string value: ""
    property string accessibleName: ""
    // The segments share the control's width equally (macOS 27 Battery's Last 24 Hours / Last 10 Days).
    property bool fill: false
    // The selected segment in the selection colour with its text colour, filling its place, instead of the raised pill, and a
    // hairline between two unselected segments (macOS 27 Battery, Sound, Trackpad).
    property bool prominent: false

    // The accent only while the window looks key, inside an app window (Appearance.accentShown, UI audit 2026-11-05 U17).
    readonly property bool keyLook: Appearance.accentShown(root.Window.window, root.Window.active)

    signal picked(string id)

    readonly property int currentIndex: {
        for (let i = 0; i < root.model.length; i++) {
            if (root.model[i].id === root.value)
                return i;
        }
        return -1;
    }

    implicitWidth: row.implicitWidth
    // As tall as a push button and a pop-up button (UI audit 2026-11-05 U19).
    implicitHeight: Tokens.controlButtonHeight
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.Grouping
    Accessible.name: root.accessibleName
    Accessible.description: root.currentIndex >= 0 ? root.model[root.currentIndex].text : ""
    Accessible.focusable: true

    function step(direction: int): void {
        if (root.model.length === 0)
            return;
        const next = Math.max(0, Math.min(root.model.length - 1, (root.currentIndex < 0 ? 0 : root.currentIndex) + direction));
        if (next !== root.currentIndex)
            root.picked(root.model[next].id);
    }

    Keys.onPressed: event => {
        if (!root.visible || !root.enabled) {
            event.accepted = ActivationKeys.navigation(event.key);
            return;
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.step(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
            root.step(1);
            event.accepted = true;
        }
    }

    // The selected pill sits this far inside the track, on whole pixels, with a concentric radius.
    readonly property int pillInset: Tokens.controlSegmentPillInset

    background: Rectangle {
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

        // One selection pill that slides to the chosen segment (macOS 27; UI audit 2026-11-05 LOW: it jumped from segment to
        // segment), raised by the switch knob's soft shadow. Prominent (macOS 27 tabs): it fills the segment's whole place, with
        // the track's corners, in the selection colour. It slides only when the choice changes, not while the row lays out.
        Rectangle {
            id: pill
            readonly property Item segment: root.currentIndex >= 0 && segments.count > root.currentIndex ? segments.itemAt(root.currentIndex) : null
            readonly property real inset: root.prominent ? 0 : root.pillInset
            property bool sliding: false
            visible: pill.segment !== null
            x: (pill.segment ? pill.segment.x : 0) + pill.inset
            y: pill.inset
            width: Math.max(0, (pill.segment ? pill.segment.width : 0) - 2 * pill.inset)
            height: parent.height - 2 * pill.inset
            radius: Tokens.radiusControl - pill.inset
            // A raised pill: white in the light appearance, a lighter grey in the dark one, with a fine edge.
            color: root.prominent ? (root.keyLook ? Appearance.colors.selection : Appearance.inactiveFill)
                : (Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2) : Appearance.colors.windowBackground)
            border.width: root.prominent ? 0 : Tokens.controlBorderWidth
            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Appearance.separatorOpacity)

            RectangularShadow {
                visible: !root.prominent
                anchors.fill: parent
                z: -1
                radius: parent.radius
                blur: Tokens.controlKnobShadowBlur
                offset: Qt.vector2d(0, Tokens.controlKnobShadowOffsetY)
                color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.controlKnobShadowOpacity)
            }

            Behavior on x {
                enabled: pill.sliding && !Appearance.reduceMotion
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionNormal)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curve
                    onRunningChanged: if (!running)
                        pill.sliding = false
                }
            }
            Behavior on width {
                enabled: pill.sliding && !Appearance.reduceMotion
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionNormal)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curve
                }
            }
        }
    }

    onCurrentIndexChanged: pill.sliding = true

    contentItem: Row {
        id: row

        Repeater {
            id: segments
            model: root.model

            delegate: T.AbstractButton {
                id: segment

                required property var modelData
                required property int index
                readonly property bool selected: segment.index === root.currentIndex

                width: root.fill && root.model.length > 0 ? root.width / root.model.length : Math.ceil(label.implicitWidth + 2 * Tokens.spacingLg)
                height: root.height
                text: segment.modelData.text
                hoverEnabled: true
                // One tab stop for the whole control (the arrow keys move inside it).
                focusPolicy: Qt.NoFocus
                Accessible.role: Accessible.RadioButton
                Accessible.name: segment.modelData.text
                Accessible.checkable: true
                Accessible.checked: segment.selected
                Accessible.onPressAction: if (segment.visible && segment.enabled && root.visible && root.enabled)
                    root.picked(segment.modelData.id)
                Accessible.onToggleAction: if (segment.visible && segment.enabled && root.visible && root.enabled)
                    root.picked(segment.modelData.id)
                onClicked: {
                    root.forceActiveFocus();
                    root.picked(segment.modelData.id);
                }

                background: Item {
                    // The hover and press shades of a segment that is not selected (the selected one is the track's pill).
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: root.prominent ? 0 : root.pillInset
                        radius: Tokens.radiusControl - anchors.margins
                        color: Appearance.withAlpha(Appearance.colors.hover, segment.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
                        visible: !segment.selected && root.enabled && (segment.hovered || segment.down)
                    }

                    // Prominent: a hairline between two unselected segments (macOS 27 tabs).
                    Rectangle {
                        visible: root.prominent && segment.index > 0 && !segment.selected && segment.index - 1 !== root.currentIndex
                        y: Math.round((parent.height - height) / 2)
                        width: Tokens.controlBorderWidth
                        height: Tokens.controlSegmentDividerHeight
                        color: Appearance.withAlpha(Appearance.colors.text, Tokens.controlSegmentDividerOpacity)
                    }
                }

                contentItem: Text {
                    id: label
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: segment.text
                    opacity: Appearance.dimsDisabled(root) ? Tokens.materialDisabledOpacity : 1
                    color: segment.selected && root.prominent && root.keyLook ? Appearance.colors.selectionText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.weight: Tokens.typographyMenuWeight
                }
            }
        }
    }

    FocusGuard {}

    FocusRing {
        visible: root.visualFocus
    }
}
