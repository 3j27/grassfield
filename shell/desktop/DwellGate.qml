import QtQuick
import Grassfield.Ui

// Dwell detector for hot corners: `triggered` fires once, `interval` ms after `hovering` became
// true. After firing the gate is latched: the pointer has to really leave the corner before it
// re-arms, so closing the surface the action opened (which covered the corner window and gave a
// hover exit + re-enter with a stationary pointer) does not fire it again.
//
// Leaving is proven by either
//  - `distance` (pointer px from the corner, reported while hovering the enlarged latch zone)
//    exceeding `leaveDistance`, or
//  - a hover exit later than `coverGraceMs` after firing (earlier exits are the opened surface
//    covering the window, not the pointer moving).
// No firing while `blocked` (the target surface is open).
QtObject {
    id: root

    property bool hovering: false
    property int interval: Tokens.hotCornerDwellMs
    // Pointer distance from the corner in px, updated while hovering.
    property real distance: 0
    property real leaveDistance: 8
    property int coverGraceMs: 800
    property bool blocked: false
    // True after triggered() until the pointer has left.
    property bool latched: false
    property double firedAt: 0

    signal triggered

    onHoveringChanged: {
        if (hovering) {
            if (!latched && !blocked)
                timer.restart();
        } else {
            timer.stop();
            if (latched && Date.now() - firedAt >= coverGraceMs)
                latched = false;
        }
    }

    onDistanceChanged: {
        if (latched && hovering && distance > leaveDistance)
            latched = false;
    }

    onBlockedChanged: {
        if (blocked)
            timer.stop();
    }

    readonly property Timer timer: Timer {
        interval: root.interval
        onTriggered: {
            if (root.blocked || root.latched)
                return;
            root.latched = true;
            root.firedAt = Date.now();
            root.triggered();
        }
    }
}
