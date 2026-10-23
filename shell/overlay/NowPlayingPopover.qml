import QtQuick
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter

// The Now Playing status item's popover (popup kind "nowplaying"): the same module as in Quick Settings (artwork, title,
// artist, previous / play-pause / next of the active player, Media service), on its own frosted shape.
FocusScope {
    id: root

    // The player went away (or its track ended and it has no session left) while the popover was open.
    readonly property bool alive: Media.available

    width: module.width
    height: module.height
    Accessible.role: Accessible.Window
    Accessible.name: qsTr("Now Playing")

    Keys.onEscapePressed: Popups.close()
    // Left/Right (a control that has no use for them): the previous or next status menu.
    Keys.onLeftPressed: Popups.stepMenu(-1)
    Keys.onRightPressed: Popups.stepMenu(1)
    onAliveChanged: {
        if (!root.alive)
            Qt.callLater(Popups.close);
    }

    NowPlaying {
        id: module
    }
}
