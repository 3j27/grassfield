pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Displays' resolution choices (macOS 27 "Larger Text … More Space", docs/audits/settings-parity-2026-10-26.md § Displays): one
// cell per choice across the group, each a window picture whose text is drawn larger or smaller, the choice in use ringed in
// the accent with its label bold. Labels under the first ("Larger Text"), the default ("Default") and the last ("More Space"); a
// choice without one has a hairline. A click, or Space or Return on a focused cell, chooses (`chosen(index)`).
Item {
    id: root

    // Displays.scaleChoices: [{scale, width, height, isDefault}], largest text first.
    property var choices: []
    // The choice in use (-1: none), and the one being tried, shown as chosen until the display says so.
    property int current: -1
    property int pending: -1
    property bool settable: true

    signal chosen(int index)

    readonly property int shown: root.pending >= 0 ? root.pending : root.current
    readonly property real cell: (width - 2 * Tokens.settingsDisplayChoicesInset) / Math.max(1, root.choices.length)
    readonly property real defaultScale: {
        const d = root.choices.find(c => c.isDefault);
        return d ? d.scale : 1;
    }

    function labelOf(i: int): string {
        const c = root.choices[i];
        if (c.isDefault)
            return qsTr("Default");
        if (i === 0)
            return qsTr("Larger Text");
        if (i === root.choices.length - 1)
            return qsTr("More Space");
        return "";
    }

    width: parent ? parent.width : implicitWidth
    implicitHeight: Tokens.settingsDisplayChoicesHeight
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Resolution")

    Repeater {
        model: root.choices

        delegate: Item {
            id: cellItem

            required property var modelData
            required property int index

            readonly property bool inUse: cellItem.index === root.shown
            readonly property string label: root.labelOf(cellItem.index)
            // The picture's text grows with the scale, around the default's.
            readonly property real textScale: cellItem.modelData.scale / root.defaultScale
            readonly property string accessibleName: (cellItem.label !== "" ? cellItem.label + ", " : "") + qsTr("looks like %1 × %2").arg(cellItem.modelData.width).arg(cellItem.modelData.height)

            function click(): void {
                if (root.settable)
                    root.chosen(cellItem.index);
            }

            x: Tokens.settingsDisplayChoicesInset + cellItem.index * root.cell
            width: root.cell
            height: root.height
            activeFocusOnTab: root.settable
            Accessible.role: Accessible.RadioButton
            Accessible.name: cellItem.accessibleName
            Accessible.checkable: true
            Accessible.checked: cellItem.inUse
            Accessible.focusable: root.settable
            Accessible.onPressAction: cellItem.click()

            Keys.onPressed: event => {
                if (root.settable && ActivationKeys.activation(event.key)) {
                    cellItem.click();
                    event.accepted = true;
                }
            }

            // The keyboard focus: outside the in-use ring, set off from it, in the focus colour (as ChoicePicker draws it), so
            // the choice in use shows both rings when it has the focus.
            Rectangle {
                id: focusRing
                readonly property real out: 1 + Tokens.iconModePreviewFocusGap + Tokens.controlFocusOutline
                visible: cellItem.activeFocus
                x: picture.x - focusRing.out
                y: picture.y - focusRing.out
                width: picture.width + 2 * focusRing.out
                height: width
                radius: Tokens.settingsDisplayChoiceRadius + focusRing.out
                color: "transparent"
                border.width: Tokens.controlFocusOutline
                border.color: Appearance.focusRingColor
            }

            // The choice in use: ringed in the accent, 1 outside the picture, the rest over its edge.
            Rectangle {
                id: inUseRing
                visible: cellItem.inUse
                x: picture.x - 1
                y: picture.y - 1
                width: picture.width + 2 * (picture.x - x)
                height: width
                radius: Tokens.settingsDisplayChoiceRadius + 1
                color: "transparent"
                border.width: Tokens.settingsDisplayChoiceRing
                border.color: Appearance.colors.accent
            }

            // A window: its controls and lines of text, larger for larger text.
            Rectangle {
                id: picture
                x: Math.round((cellItem.width - width) / 2)
                y: Tokens.settingsDisplayChoiceTop
                width: Tokens.settingsDisplayChoiceSize
                height: width
                radius: Tokens.settingsDisplayChoiceRadius
                color: Appearance.colors.windowBackground
                border.width: 1
                border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                clip: true

                Row {
                    x: Math.round(Tokens.settingsDisplayChoiceMargin * cellItem.textScale)
                    y: Math.round(Tokens.settingsDisplayChoiceMargin * cellItem.textScale)
                    spacing: Tokens.settingsDisplayChoiceDot / 2 * cellItem.textScale

                    Repeater {
                        model: [Tokens.windowCloseColor, Tokens.windowMinimizeColor, Tokens.windowZoomColor]

                        delegate: Rectangle {
                            required property string modelData
                            width: Tokens.settingsDisplayChoiceDot * cellItem.textScale
                            height: width
                            radius: width / 2
                            color: modelData
                        }
                    }
                }

                Column {
                    x: Math.round(Tokens.settingsDisplayChoiceMargin * cellItem.textScale)
                    y: Math.round(Tokens.settingsDisplayChoiceTextTop * cellItem.textScale)
                    spacing: Tokens.settingsDisplayChoiceTextGap * cellItem.textScale

                    // As many lines as the picture holds at the default size; the last of every three is shorter (a paragraph's end).
                    Repeater {
                        model: Math.ceil(Tokens.settingsDisplayChoiceSize / (Tokens.settingsDisplayChoiceText + Tokens.settingsDisplayChoiceTextGap))

                        delegate: Rectangle {
                            required property int index
                            width: picture.width - (index % 3 === 2 ? picture.width / 2 : 2 * Tokens.settingsDisplayChoiceMargin * cellItem.textScale)
                            height: Tokens.settingsDisplayChoiceText * cellItem.textScale
                            radius: height / 2
                            color: Appearance.withAlpha(Appearance.colors.text, Tokens.materialDisabledOpacity)
                        }
                    }
                }
            }

            Text {
                visible: cellItem.label !== ""
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                y: Tokens.settingsDisplayChoiceLabelBaseline - baselineOffset
                text: cellItem.label
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: cellItem.inUse ? Tokens.typographyMenuBoldWeight : Font.Normal
            }

            Rectangle {
                visible: cellItem.label === ""
                x: Tokens.settingsDisplayChoiceLineInset
                y: Tokens.settingsDisplayChoiceLineY
                width: cellItem.width - 2 * Tokens.settingsDisplayChoiceLineInset
                height: 1
                color: Appearance.withAlpha(Appearance.colors.separator, Tokens.settingsDisplayChoiceLineOpacity)
            }

            MouseArea {
                anchors.fill: parent
                enabled: root.settable
                onClicked: cellItem.click()
            }
        }
    }
}
