pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Segmented choice of 2-4 options. model: [{id, text}]; value is the selected id; picked(id) on user change.
Item {
    id: root

    property var model: []
    property string value: ""
    property string accessibleName: ""

    signal picked(string id)

    readonly property int currentIndex: {
        for (let i = 0; i < root.model.length; i++) {
            if (root.model[i].id === root.value)
                return i;
        }
        return -1;
    }

    implicitWidth: row.implicitWidth
    implicitHeight: Tokens.menuItemHeight + Tokens.spacingSm
    activeFocusOnTab: true
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
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.step(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
            root.step(1);
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: root.activeFocus ? Tokens.controlFocusRing : 0
        border.color: Appearance.colors.accent
    }

    Row {
        id: row
        anchors.fill: parent

        Repeater {
            model: root.model

            delegate: Item {
                id: segment

                required property var modelData
                required property int index
                readonly property bool selected: segment.index === root.currentIndex

                width: label.implicitWidth + 2 * Tokens.spacingLg
                height: root.height
                Accessible.role: Accessible.RadioButton
                Accessible.name: segment.modelData.text
                Accessible.checkable: true
                Accessible.checked: segment.selected
                Accessible.onPressAction: root.picked(segment.modelData.id)

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: Tokens.controlFocusRing / 2
                    radius: Tokens.radiusControl
                    color: Appearance.colors.accent
                    visible: segment.selected
                }

                Text {
                    id: label
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: segment.modelData.text
                    color: segment.selected ? Appearance.colors.accentText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.weight: Tokens.typographyMenuWeight
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.ArrowCursor
                    onClicked: {
                        root.forceActiveFocus();
                        root.picked(segment.modelData.id);
                    }
                }
            }
        }
    }
}
