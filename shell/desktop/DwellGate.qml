import QtQuick
import Grassfield.Ui

// Dwell detector for hot corners (macOS: a corner fires once when the pointer enters it, never again until the pointer
// has left it): `triggered` fires once, `interval` ms after `hovering` became true. After firing the gate is latched
// until the pointer has truly left the corner, so closing the surface the action opened (which covered the corner window
// and gave a hover exit + re-enter with a pointer that never moved) does not fire it again.
//
// The corner window never grows (it must not cover controls), so leaving is proven by either
//  - `pointerSeen(distance)`: a position more than `leaveDistance` px from the corner, reported by another surface under
//    the pointer (menu bar, wallpaper, Dock, through PointerTracker) or by the compositor when the gate asks for it
//    (`positionWanted`: HotCorner reads the pointer from Hyprland, so it works over full-screen windows too), or
//  - a hover exit while nothing `covered` the window: no full-attention shell surface (Apps, Overview, Search, a menu,
//    the switcher, the Notification Center) and no session lock was up, so the pointer itself moved out.
// While one is up a hover exit may be that surface covering the window (however late it appears) or a real leave (the
// Notification Center and Search leave the menu-bar strip, and so the top corners, uncovered): the gate asks where the
// pointer is. It asks again when the last one closes while the corner window is not hovered (the pointer moved on while
// the surface covered it). No timing is involved.
// No firing while `blocked` (the target surface is open, or the session is locked).
QtObject {
    id: root

    property bool hovering: false
    property int interval: Tokens.hotCornerDwellMs
    property real leaveDistance: 8
    // A full-attention shell surface or the session lock is up: it may cover the corner window (HotCorners binds it).
    property bool covered: false
    property bool blocked: false
    // True after triggered() until the pointer has left.
    property bool latched: false

    signal triggered
    // The gate needs the pointer's position: answer with pointerSeen(distance from the corner).
    signal positionWanted

    // A position reported by a surface other than the corner window: distance from the corner in px.
    function pointerSeen(distance: real): void {
        if (latched && distance > leaveDistance)
            latched = false;
    }

    onHoveringChanged: {
        if (hovering) {
            if (!latched && !blocked)
                timer.restart();
        } else {
            timer.stop();
            if (latched && !covered)
                latched = false;
            else if (latched)
                positionWanted();
        }
    }

    onCoveredChanged: {
        if (!covered && latched && !hovering)
            positionWanted();
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
            root.triggered();
        }
    }
}
