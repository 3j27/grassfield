import QtQuick
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter

// Now Playing tile (CC7): artwork, title, artist and transport controls of the active MPRIS player.
// Hidden by the host when Media.available is false.
Tile {
    id: root

    padding: Tokens.spacingSm + Tokens.spacingXs
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Now Playing")

    Row {
        width: parent.width
        spacing: Tokens.spacingSm

        Rectangle {
            width: Tokens.panelCcArtSize
            height: width
            radius: Tokens.radiusControl
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            clip: true

            Image {
                anchors.fill: parent
                source: Media.artUrl
                sourceSize: Qt.size(Tokens.panelCcArtSize * 2, Tokens.panelCcArtSize * 2)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }

        Column {
            width: parent.width - Tokens.panelCcArtSize - parent.spacing
            anchors.verticalCenter: parent.verticalCenter

            Label {
                width: parent.width
                text: Media.title !== "" ? Media.title : qsTr("Not playing")
            }

            Caption {
                width: parent.width
                visible: text !== ""
                text: Media.artist
            }
        }
    }

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Tokens.spacingSm

        Repeater {
            model: [
                {icon: "media-prev", name: qsTr("Previous track"), action: "previous"},
                {icon: Media.playing ? "media-pause" : "media-play", name: Media.playing ? qsTr("Pause") : qsTr("Play"), action: "toggle"},
                {icon: "media-next", name: qsTr("Next track"), action: "next"}
            ]

            delegate: NavItem {
                id: button

                required property var modelData

                width: Tokens.panelCcIconButton - Tokens.spacingXs
                height: width
                accessibleName: modelData.name
                ringRadius: width / 2
                onActivated: {
                    if (modelData.action === "toggle")
                        Media.togglePlaying();
                    else if (modelData.action === "next")
                        Media.next();
                    else
                        Media.previous();
                }

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.menuIconSize
                    name: button.modelData.icon
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        button.forceActiveFocus();
                        button.activated();
                    }
                }
            }
        }
    }
}
