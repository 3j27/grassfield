import QtQuick
import Grassfield.Ui

// The procedural Grassfield artworks (ui/Grassfield/Ui/GrassfieldArtwork.qml, shared with the Settings > Wallpaper tiles), as
// the desktop wallpaper and the lock screen backdrop draw them. A wrapper so that those two keep their name. Without
// `artwork` and `variant` it draws the Grassfield evening of the dark set, the lock's picture until ADR-0040 step 4a.
Item {
    id: root

    property alias artwork: inner.artwork
    property alias variant: inner.variant
    // The moving variant (ADR-0040 step 9): drawn when `moving`, advancing while `playing`.
    property alias moving: inner.moving
    property alias playing: inner.playing
    // Artwork palette (the desktop reads the tone's colours for the menu bar and every colour for the glass backdrop).
    readonly property alias art: inner.art
    readonly property alias palette: inner.palette

    GrassfieldArtwork {
        id: inner
        anchors.fill: parent
    }
}
