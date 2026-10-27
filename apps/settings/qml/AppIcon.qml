import QtQuick
import Grassfield.Ui

// A desktop entry's icon (image://icon: the icon theme, or an absolute path), else a graphite tile with the apps glyph.
Item {
    id: root

    property string icon: ""

    implicitWidth: Tokens.settingsNavTileSize
    implicitHeight: Tokens.settingsNavTileSize

    Image {
        id: picture
        anchors.fill: parent
        source: root.icon !== "" ? "image://icon/" + root.icon : ""
        sourceSize: Qt.size(2 * root.width, 2 * root.height)
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
        // The provider answers 1 x 1 for an icon it does not know.
        visible: status === Image.Ready && implicitWidth > 1
    }

    Rectangle {
        anchors.fill: parent
        visible: !picture.visible
        radius: Tokens.settingsNavTileRadius
        color: Tokens.colorAccentLight.graphite

        Icon {
            anchors.centerIn: parent
            name: "apps"
            size: Tokens.settingsNavGlyphSize
            color: Tokens.settingsSidebarTileGlyph
        }
    }
}
