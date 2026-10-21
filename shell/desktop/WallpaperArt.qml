import QtQuick
import Grassfield.Ui

// The procedural Grassfield artwork (ui/Grassfield/Ui/GrassfieldArtwork.qml, shared with the Settings > Wallpaper tile),
// as the desktop wallpaper and, blurred, the lock screen backdrop draw it. A wrapper so that those two keep their name.
Item {
    id: root

    // Artwork palette (the desktop reads the sky colours for the menu bar tone).
    readonly property alias art: inner.art

    GrassfieldArtwork {
        id: inner
        anchors.fill: parent
    }
}
