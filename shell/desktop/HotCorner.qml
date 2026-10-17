import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services

// One hot corner trigger: a tiny transparent layer-shell window in a screen corner
// (namespace grassfield-hotcorner, no exclusive zone, no keyboard). Not mapped while its
// action is "none", so it never intercepts anything then.
//
// The window never grows: the latch is released by PointerTracker positions (see DwellGate).
//
// Click safety: the window is Tokens.hotCornerSize px square in the very corner. The menu bar
// buttons start spacingXs px from the screen edge and the Dock is centered, so no control is
// covered; the pointer pressed into a corner pixel does not click a bar item.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: win

    // topLeft | topRight | bottomLeft | bottomRight
    property string corner: "topLeft"
    property string action: "none"
    // True while the surface the action opens is open (no firing then).
    property bool blocked: false

    signal fire

    readonly property alias gate: dwell

    visible: action !== "none"
    anchors {
        top: win.corner.startsWith("top")
        bottom: win.corner.startsWith("bottom")
        left: win.corner.endsWith("Left")
        right: win.corner.endsWith("Right")
    }
    implicitWidth: Tokens.hotCornerSize
    implicitHeight: Tokens.hotCornerSize
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    focusable: false
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "grassfield-hotcorner"

    DwellGate {
        id: dwell
        hovering: hover.hovered
        blocked: win.blocked
        onTriggered: win.fire()
    }

    // Pointer positions seen by other surfaces on this screen prove the pointer left the corner.
    Connections {
        target: PointerTracker

        function onMoved(screenName: string, x: real, y: real): void {
            if (!win.screen || screenName !== win.screen.name)
                return;
            const dx = win.corner.endsWith("Left") ? x : win.screen.width - x;
            const dy = win.corner.startsWith("top") ? y : win.screen.height - y;
            dwell.pointerSeen(Math.max(dx, dy));
        }
    }

    Item {
        anchors.fill: parent

        HoverHandler {
            id: hover
        }
    }
}
