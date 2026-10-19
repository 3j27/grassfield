import QtQuick
import Grassfield.Ui

// Accessibility (macOS model: Accessibility > Display > Pointer). First slice: Pointer size only; pointer outline and
// fill colours come later (they need the cursor theme to be regenerated, docs/specs/settings.md, Pointer).
SettingsPage {
    id: root

    required property var store

    title: qsTr("Accessibility")

    // A size change is waiting to be shown by the pointer; the shape toggle that makes the compositor load it.
    property bool changed: false
    property bool grip: false

    // Twice the shell's throttle: by then the shell has asked the compositor for the size written by the last step.
    Timer {
        id: refresh
        interval: 2 * Tokens.settingsPointerApplyMs
        onTriggered: {
            if (root.changed) {
                root.changed = false;
                root.grip = !root.grip;
                refresh.start();
            } else if (root.grip) {
                root.grip = false;
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Pointer")
        footnote: qsTr("The pointer changes size as you drag. Apps that are already open keep their size until they are restarted.")

        SettingsRow {
            title: qsTr("Pointer size")
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Normal")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
            Slider {
                id: size
                width: Tokens.controlSliderDefaultWidth
                accessibleName: qsTr("Pointer size")
                from: PointerSize.MIN
                to: PointerSize.MAX
                stepSize: PointerSize.STEP / (PointerSize.MAX - PointerSize.MIN)
                value: root.store.value("pointer.size")
                // The compositor draws the pointer and takes a new size only when a client sets a shape, so the shape
                // alternates while the size changes: the pointer under the slider follows the drag.
                cursorShape: root.grip ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                onMoved: v => {
                    root.store.set("pointer.size", PointerSize.snap(v));
                    size.reset();
                    root.changed = true;
                    if (!refresh.running)
                        refresh.start();
                }
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Large")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }
    }
}
