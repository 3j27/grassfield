pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The + / − footer of a list inside a SettingsGroup (macOS: under a table): a top line, a slightly darker fill, then two
// 24-wide borderless buttons with a divider after each (docs/audits/settings-parity-2026-10-26.md § Login Items). The last row
// of the group: its bottom corners follow the group's.
Item {
    id: root

    property bool canAdd: true
    property bool canRemove: false
    property string addName: ""
    property string removeName: ""

    signal addClicked
    signal removeClicked

    width: parent ? parent.width : implicitWidth
    implicitHeight: Tokens.settingsFooterHeight

    // The fill (opaque, so the two shapes do not add up), its top corners square, its bottom ones the group's.
    readonly property color fill: Qt.tint(Appearance.colors.groupFill, Appearance.withAlpha(Appearance.colors.text, Tokens.settingsFooterFillOpacity))
    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusMenu
        color: root.fill
    }
    Rectangle {
        width: parent.width
        height: Math.min(parent.height, Tokens.radiusMenu)
        color: root.fill
    }
    Rectangle {
        width: parent.width
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Row {
        y: 1
        height: parent.height - 1

        Repeater {
            model: [{add: true}, {add: false}]

            Item {
                id: cell
                required property var modelData
                width: Tokens.settingsFooterButtonWidth + 1
                height: parent.height

                ToolButton {
                    width: Tokens.settingsFooterButtonWidth
                    height: parent.height
                    buttonSize: Tokens.settingsFooterButtonWidth
                    glyphSize: Tokens.settingsFooterGlyphSize
                    iconName: cell.modelData.add ? "plus" : "minus"
                    tint: Appearance.windowSecondary
                    enabled: cell.modelData.add ? root.canAdd : root.canRemove
                    accessibleName: cell.modelData.add ? root.addName : root.removeName
                    onClicked: cell.modelData.add ? root.addClicked() : root.removeClicked()
                }
                Rectangle {
                    x: Tokens.settingsFooterButtonWidth
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1
                    height: parent.height - 2 * Tokens.spacingXs
                    color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }
            }
        }
    }
}
