import QtQuick
import Grassfield.Ui

// One login item in Settings > General > Login Items: the app's icon, its name, where it comes from, a switch. A click selects
// the row (the list's − then acts on it); the selected row has the selection colours, as a table row (macOS). Privacy &
// Security's lists use it too, its saved selections without the switch (`showToggle`).
Item {
    id: root

    property string icon: ""
    property string title: ""
    property string subtitle: ""
    property bool checked: false
    property bool selected: false
    property bool toggleEnabled: true
    property bool showToggle: true

    signal clicked
    signal toggled(bool checked)

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(Tokens.settingsRowHeight, labels.implicitHeight + 2 * Tokens.spacingSm)
    Accessible.role: Accessible.ListItem
    Accessible.name: root.subtitle !== "" ? root.title + ", " + root.subtitle : root.title
    Accessible.selected: root.selected

    Rectangle {
        visible: root.Positioner.index > 0 && !root.selected
        x: Tokens.settingsRowInset
        width: parent.width - 2 * Tokens.settingsRowInset
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Tokens.spacingXs
        visible: root.selected
        radius: Tokens.settingsNavTileRadius
        color: Appearance.colors.selection
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.clicked()
    }

    AppIcon {
        x: Tokens.settingsNavTileInset
        anchors.verticalCenter: parent.verticalCenter
        icon: root.icon
    }

    Column {
        id: labels
        anchors {
            left: parent.left
            leftMargin: Tokens.settingsNavLabelInset
            right: root.showToggle ? toggle.left : parent.right
            rightMargin: root.showToggle ? Tokens.spacingLg : Tokens.settingsRowInset
            verticalCenter: parent.verticalCenter
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: root.title
            color: root.selected ? Appearance.colors.selectionText : Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
        Text {
            textFormat: Text.PlainText
            visible: root.subtitle !== ""
            width: parent.width
            elide: Text.ElideRight
            text: root.subtitle
            color: root.selected ? Appearance.colors.selectionText : Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }
    }

    Toggle {
        id: toggle
        anchors {
            right: parent.right
            rightMargin: Tokens.settingsRowInset
            verticalCenter: parent.verticalCenter
        }
        visible: root.showToggle
        enabled: root.toggleEnabled
        accessibleName: root.title
        checked: root.checked
        onToggled: c => root.toggled(c)
    }
}
