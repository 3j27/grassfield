pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Displays.js" as Displays

// The band at the top of Displays (macOS 27, docs/audits/settings-parity-2026-10-26.md § Displays): across the whole pane from its
// top, white darkening a little to a separator; each display's picture (a laptop for a built-in panel, else a display) and name,
// centred. With several displays a click, or Space or Return on a focused one, chooses the display the groups below set; its
// name is bold, the others' secondary. The first item of the page's column: the band is drawn out to the pane's top and sides.
Item {
    id: root

    property var monitors: []
    property string selected: ""
    // The pane's width (the band spans it, not just the column).
    property real paneWidth: width

    signal picked(string name)

    readonly property real columnX: parent ? parent.x : 0
    readonly property bool several: root.monitors.length > 1

    function nameOf(m: var): string {
        if (Displays.isBuiltIn(m))
            return qsTr("Built-in Display");
        const model = String(m.model).trim();
        return model !== "" ? model : m.name;
    }

    width: parent ? parent.width : implicitWidth
    // The first group comes settingsDisplayFirstGroupY below the pane's top; the column adds its gap after this item.
    implicitHeight: Tokens.settingsDisplayFirstGroupY - Tokens.settingsContentTop - Tokens.settingsGroupGap
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Displays")

    Rectangle {
        x: -root.columnX
        y: -Tokens.settingsContentTop
        width: root.paneWidth
        height: Tokens.settingsDisplaySeparatorY
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Appearance.withAlpha(Appearance.colors.text, 0)
            }
            GradientStop {
                position: 1
                color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsDisplayBandOpacity)
            }
        }
    }

    Rectangle {
        x: -root.columnX
        y: Tokens.settingsDisplaySeparatorY - Tokens.settingsContentTop
        width: root.paneWidth
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.settingsDisplayPictureTop - Tokens.settingsContentTop
        spacing: Tokens.settingsDisplayPictureGap

        Repeater {
            model: root.monitors

            delegate: Item {
                id: entry

                required property var modelData
                readonly property bool isSelected: entry.modelData.name === root.selected

                width: Math.max(Tokens.settingsDisplayPictureWidth, label.implicitWidth)
                height: Tokens.settingsDisplayNameBaseline - Tokens.settingsDisplayPictureTop + label.height - label.baselineOffset
                activeFocusOnTab: root.several
                Accessible.role: Accessible.RadioButton
                Accessible.name: label.text
                Accessible.checkable: true
                Accessible.checked: entry.isSelected
                Accessible.focusable: root.several
                Accessible.onPressAction: root.picked(entry.modelData.name)

                Keys.onPressed: event => {
                    if (ActivationKeys.activation(event.key)) {
                        root.picked(entry.modelData.name);
                        event.accepted = true;
                    }
                }

                DevicePicture {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Tokens.settingsDisplayPictureWidth
                    height: Tokens.settingsDisplayPictureHeight
                    kind: Displays.isBuiltIn(entry.modelData) ? "laptop" : "desktop"
                }

                Text {
                    id: label
                    textFormat: Text.PlainText
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Tokens.settingsDisplayNameBaseline - Tokens.settingsDisplayPictureTop - baselineOffset
                    text: root.nameOf(entry.modelData)
                    color: entry.isSelected || !root.several ? Appearance.colors.text : Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    font.weight: entry.isSelected || !root.several ? Tokens.typographyMenuBoldWeight : Font.Normal
                }

                Rectangle {
                    visible: entry.activeFocus
                    anchors.fill: parent
                    anchors.margins: -Tokens.controlFocusOutline
                    radius: Tokens.radiusGroup
                    color: "transparent"
                    border.width: Tokens.controlFocusOutline
                    border.color: Appearance.focusRingColor
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.several
                    onClicked: root.picked(entry.modelData.name)
                }
            }
        }
    }
}
