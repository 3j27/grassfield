pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Grassfield.Ui

// The accent colours of Settings > Appearance > Theme (macOS 27, docs/audits/settings-parity-2026-10-26.md § Appearance):
// one round swatch per accent, in its colour in the current appearance (Multicolour a colour wheel), the chosen one in an
// accent ring with its name under it. One focus stop: Left/Right (and Up/Down) move the choice; the keyboard focus is a ring
// in the focus colour outside the selection ring. The box is the swatches with room for the ring; the name may reach past it.
FocusScope {
    id: root

    // [{color, name}], in the order of Accent.NAMES; the first one is Multicolour.
    property var model: []
    property int currentIndex: -1
    property string accessibleName: ""

    signal chosen(int index)

    readonly property real ringPad: Tokens.settingsChoiceRingWidth + Tokens.settingsAccentRingGap
    readonly property real pitch: Tokens.settingsAccentSwatchSize + Tokens.settingsAccentSwatchGap

    implicitWidth: root.model.length > 0 ? (root.model.length - 1) * root.pitch + Tokens.settingsAccentSwatchSize + 2 * root.ringPad : 0
    implicitHeight: root.ringPad + Tokens.settingsAccentSwatchSize + Tokens.settingsAccentCaptionBaseline + Tokens.spacingXs
    activeFocusOnTab: true
    Accessible.role: Accessible.RadioButton
    Accessible.name: root.accessibleName
    Accessible.description: root.currentIndex >= 0 && root.currentIndex < root.model.length ? root.model[root.currentIndex].name : ""
    Accessible.focusable: true

    function step(direction: int): void {
        if (root.model.length === 0)
            return;
        const next = Math.max(0, Math.min(root.model.length - 1, (root.currentIndex < 0 ? 0 : root.currentIndex) + direction));
        if (next !== root.currentIndex)
            root.chosen(next);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.step(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
            root.step(1);
            event.accepted = true;
        }
    }

    Repeater {
        model: root.model

        delegate: Item {
            id: swatch

            required property var modelData
            required property int index
            readonly property bool selected: swatch.index === root.currentIndex
            readonly property real size: Tokens.settingsAccentSwatchSize

            x: root.ringPad + swatch.index * root.pitch
            y: root.ringPad
            width: swatch.size
            height: swatch.size
            Accessible.role: Accessible.RadioButton
            Accessible.name: swatch.modelData.name
            Accessible.checkable: true
            Accessible.checked: swatch.selected
            Accessible.onPressAction: root.chosen(swatch.index)

            Rectangle {
                anchors.centerIn: parent
                width: swatch.size + 2 * (root.ringPad + Tokens.iconModePreviewFocusGap + Tokens.controlFocusOutline)
                height: width
                radius: width / 2
                color: "transparent"
                border.width: Tokens.controlFocusOutline
                border.color: Appearance.focusRingColor
                visible: swatch.selected && root.activeFocus
            }

            Rectangle {
                anchors.centerIn: parent
                width: swatch.size + 2 * root.ringPad
                height: width
                radius: width / 2
                color: "transparent"
                border.width: Tokens.settingsChoiceRingWidth
                border.color: Appearance.colors.accent
                visible: swatch.selected
            }

            Rectangle {
                visible: swatch.index > 0
                anchors.fill: parent
                radius: width / 2
                color: swatch.modelData.color
            }

            // Multicolour: a colour wheel of the other accents.
            Shape {
                visible: swatch.index === 0
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: "transparent"
                    fillGradient: ConicalGradient {
                        centerX: swatch.size / 2
                        centerY: swatch.size / 2
                        angle: 90
                        GradientStop {
                            position: 0
                            color: root.model.length > 1 ? root.model[1].color : "transparent"
                        }
                        GradientStop {
                            position: 0.17
                            color: root.model.length > 2 ? root.model[2].color : "transparent"
                        }
                        GradientStop {
                            position: 0.33
                            color: root.model.length > 3 ? root.model[3].color : "transparent"
                        }
                        GradientStop {
                            position: 0.5
                            color: root.model.length > 4 ? root.model[4].color : "transparent"
                        }
                        GradientStop {
                            position: 0.67
                            color: root.model.length > 5 ? root.model[5].color : "transparent"
                        }
                        GradientStop {
                            position: 0.83
                            color: root.model.length > 7 ? root.model[7].color : "transparent"
                        }
                        GradientStop {
                            position: 1
                            color: root.model.length > 1 ? root.model[1].color : "transparent"
                        }
                    }
                    PathAngleArc {
                        centerX: swatch.size / 2
                        centerY: swatch.size / 2
                        radiusX: swatch.size / 2
                        radiusY: swatch.size / 2
                        startAngle: 0
                        sweepAngle: 360
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "transparent"
                border.width: Tokens.appsBorderWidth
                border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            Text {
                visible: swatch.selected
                textFormat: Text.PlainText
                x: Math.round((swatch.size - width) / 2)
                y: swatch.size + Tokens.settingsAccentCaptionBaseline - baselineOffset
                text: swatch.modelData.name
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.settingsCaptionDetailSize
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -Tokens.settingsAccentSwatchGap / 2
                cursorShape: Qt.ArrowCursor
                onClicked: {
                    root.forceActiveFocus();
                    root.chosen(swatch.index);
                }
            }
        }
    }
}
