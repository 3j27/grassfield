import QtQuick
import Grassfield.Ui

// Keeps an Exclusive layer surface mapped for a moment after it stops holding the keyboard. A layer that is destroyed while
// Exclusive leaves Hyprland with no keyboard focus at all (it names no window, though it still reports one active); a layer
// that drops to keyboard None first, and unmaps later, gives the focus back. Use: `visible: release.mapped`,
// `keyboardFocus: shown ? Exclusive : None`, `release.shown: shown`, and an empty input mask once not shown
// (`mask: shown ? <its mask or null> : <empty Region>`): the held surface is invisible, so a click during the hold belongs to
// the window under it (the hold also outlasts its timer whenever the shell's GUI thread is busy: measured up to several
// seconds in a loaded nested session, tests/compositor/click_focus.sh). Surfaces that fade out (Apps) are already mapped
// long enough and need not use it.
QtObject {
    id: root

    // The surface is wanted (it holds the keyboard).
    property bool shown: false
    // Map the surface while `shown`, and for focusReturn.releaseHoldMs after.
    readonly property bool mapped: shown || holding
    property bool holding: false

    onShownChanged: {
        if (shown) {
            holding = false;
            hold.stop();
        } else {
            holding = true;
            hold.restart();
        }
    }

    readonly property Timer hold: Timer {
        interval: Tokens.focusReturnReleaseHoldMs
        onTriggered: root.holding = false
    }
}
