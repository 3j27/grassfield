import QtQuick
import Grassfield.Ui

// The device picture: Grassfield's own drawing of a laptop or a display with the Grassfield artwork on its screen, in the
// place and size of the macOS picture (macOS draws Apple artwork there). kind: "laptop" or "desktop" (Settings derives it
// from hostname1's chassis, General.deviceKind). Shared through Grassfield.Ui (ADR-0040 step 1a): Settings > General > About,
// Displays and the About This Computer window (step 1b) draw it.
Item {
    id: root

    property string kind: "laptop"
    readonly property bool laptop: root.kind === "laptop"
    // The screen: the whole width less the base's overhang for a laptop; a display keeps room for its stand.
    readonly property real screenWidth: root.laptop ? Math.round(width * 0.85) : width
    readonly property real screenHeight: root.laptop ? height - Math.round(height * 0.08) : Math.round(height * 0.8)
    readonly property real bezel: Math.max(2, Math.round(width * 0.025))

    implicitWidth: Tokens.settingsAboutPictureWidth
    implicitHeight: Tokens.settingsAboutPictureHeight
    Accessible.ignored: true

    Rectangle {
        id: screen
        x: Math.round((root.width - width) / 2)
        width: root.screenWidth
        height: root.screenHeight
        radius: root.bezel + 1
        color: Tokens.settingsDeviceBezel

        Item {
            anchors.fill: parent
            anchors.margins: root.bezel
            clip: true

            GrassfieldArtwork {
                anchors.fill: parent
            }
        }
    }

    // Laptop: the base, wider than the screen, with the thumb notch.
    Rectangle {
        visible: root.laptop
        anchors.bottom: parent.bottom
        width: root.width
        height: root.height - screen.height
        radius: height / 2
        color: Tokens.settingsDeviceBody

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(root.width * 0.16)
            height: Math.max(1, Math.round(parent.height * 0.35))
            radius: height / 2
            color: Tokens.settingsDeviceBodyShade
        }
    }

    // Display: the neck and the foot of the stand.
    Rectangle {
        visible: !root.laptop
        anchors.horizontalCenter: parent.horizontalCenter
        y: screen.height
        width: Math.round(root.width * 0.12)
        height: root.height - screen.height - foot.height
        color: Tokens.settingsDeviceBodyShade
    }

    Rectangle {
        id: foot
        visible: !root.laptop
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        width: Math.round(root.width * 0.36)
        height: Math.max(2, Math.round(root.height * 0.05))
        radius: height / 2
        color: Tokens.settingsDeviceBody
    }
}
