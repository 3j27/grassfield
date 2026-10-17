import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui

// One hot corner trigger: a tiny transparent layer-shell window in a screen corner
// (namespace grassfield-hotcorner, no exclusive zone, no keyboard). Not mapped while its
// action is "none", so it never intercepts anything then.
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
        onTriggered: win.fire()
    }

    Item {
        anchors.fill: parent

        HoverHandler {
            id: hover
        }
    }
}
