pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Segmented size choice (Small | Medium | Large) for the gallery. Tab moves between segments,
// Space or Return picks one.
Row {
    id: root

    property var sizes: []
    property string current: ""

    signal picked(string size)

    spacing: 0
    Accessible.role: Accessible.RadioButton
    Accessible.name: qsTr("Widget size")

    Repeater {
        model: root.sizes

        delegate: Item {
            id: segment

            required property string modelData
            required property int index
            readonly property bool selected: modelData === root.current

            width: Tokens.widgetSizeButtonWidth
            height: Tokens.menuItemHeight
            z: segmentFocus.active ? 1 : 0
            activeFocusOnTab: true
            Accessible.role: Accessible.RadioButton
            Accessible.name: Registry.sizeLabel(modelData)
            Accessible.checked: selected
            Accessible.focusable: true
            Accessible.onPressAction: root.picked(modelData)

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.picked(segment.modelData);
                    event.accepted = true;
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusControl
                color: segment.selected ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            }

            // The shared ring outside the segment, after a key only, above its neighbours (ADR-0039 step 7).
            KeyFocus {
                id: segmentFocus
            }

            FocusRing {
                visible: segmentFocus.active
            }

            WidgetLabel {
                anchors.centerIn: parent
                width: parent.width - Tokens.spacingSm
                horizontalAlignment: Text.AlignHCenter
                text: Registry.sizeLabel(segment.modelData)
                font.pixelSize: Tokens.typographyCaptionSize
                color: segment.selected ? Appearance.colors.selectionText : Appearance.colors.text
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.ArrowCursor
                onClicked: {
                    segment.forceActiveFocus();
                    root.picked(segment.modelData);
                }
            }
        }
    }
}
