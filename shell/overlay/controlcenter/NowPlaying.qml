import QtQuick
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter

// Now Playing module (CC7, 2x2): artwork, title, artist and transport controls of the active MPRIS
// player. Shown while nothing plays too (macOS 27): "Not playing", the transport dimmed and inactive.
Module {
    id: root

    readonly property real pad: Tokens.quicksettingsPadding

    cols: 2
    rows: 2
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Now Playing")

    Rectangle {
        id: art
        x: root.pad
        y: root.pad
        width: Tokens.panelCcArtSize
        height: width
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        clip: true

        Image {
            anchors.fill: parent
            // Never the player's URL: a PNG the shell made from its file or https resource (ThemeIcons.artSource).
            source: ThemeIcons.artSource(Media.artShown)
            sourceSize: Qt.size(Tokens.panelCcArtSize * 2, Tokens.panelCcArtSize * 2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
    }

    // macOS: the artwork and the title open the app that plays; the panel closes.
    function openApp(): void {
        Popups.close();
        Media.openPlayerApp(true);
    }

    MouseArea {
        x: root.pad
        y: art.y
        width: root.width - 2 * root.pad
        height: art.height + titles.height + Tokens.spacingXs
        enabled: Media.available
        cursorShape: Qt.ArrowCursor
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Open the app that is playing")
        Accessible.onPressAction: root.openApp()
        onClicked: root.openApp()
    }

    Column {
        id: titles
        x: root.pad
        y: art.y + art.height + Tokens.spacingXs
        width: root.width - 2 * root.pad

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

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height - height - Tokens.spacingSm
        spacing: Tokens.spacingXs

        Repeater {
            model: [
                {icon: "media-prev", name: qsTr("Previous track"), action: "previous"},
                {icon: Media.playing ? "media-pause" : "media-play", name: Media.playing ? qsTr("Pause") : qsTr("Play"), action: "toggle"},
                {icon: "media-next", name: qsTr("Next track"), action: "next"}
            ]

            delegate: NavItem {
                id: button

                required property var modelData

                enabled: Media.available
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                width: Tokens.panelCcTransportButton
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
                    cursorShape: Qt.ArrowCursor
                    onClicked: {
                        button.forceActiveFocus();
                        button.activated();
                    }
                }
            }
        }
    }
}
