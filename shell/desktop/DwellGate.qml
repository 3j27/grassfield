import QtQuick
import Grassfield.Ui

// Dwell detector for hot corners: `triggered` fires once, `interval` ms after `hovering` became
// true. The pointer has to leave and come back to fire again.
QtObject {
    id: root

    property bool hovering: false
    property int interval: Tokens.hotCornerDwellMs
    // True after triggered() until the pointer leaves.
    property bool fired: false

    signal triggered

    onHoveringChanged: {
        fired = false;
        if (hovering)
            timer.restart();
        else
            timer.stop();
    }

    readonly property Timer timer: Timer {
        interval: root.interval
        onTriggered: {
            root.fired = true;
            root.triggered();
        }
    }
}
