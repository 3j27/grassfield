// Part of tests/compositor/fullscreen_reveal.sh (NESTED only): an Overlay layer surface of another client over the top left
// corner of the output named by GF_RV_OUTPUT (namespace reveal-fixture, 240 x 120 px from the corner, no keyboard), where
// the revealed titlebar of a full-screen window has its lights. The plugin must leave its presses alone (ADR-0015 P6:
// never under a layer popup or an Overlay layer). Every press it receives is logged ("[rv-fixture] press <x> <y>"), its
// mapping too ("[rv-fixture] mapped <output>").
// Run: WAYLAND_DISPLAY=<nested> GF_RV_OUTPUT=<output> qs -p <this dir>
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string outputName: {
        const raw = Quickshell.env("GF_RV_OUTPUT") ?? "";
        return /^[A-Za-z0-9._-]{1,32}$/.test(raw) ? raw : "";
    }

    Variants {
        model: Quickshell.screens.filter(s => s.name === root.outputName)

        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: panel

            required property ShellScreen modelData

            screen: modelData
            anchors {
                top: true
                left: true
            }
            implicitWidth: 240
            implicitHeight: 120
            exclusionMode: ExclusionMode.Ignore
            color: "#224488"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "reveal-fixture"

            MouseArea {
                anchors.fill: parent
                onPressed: mouse => console.log("[rv-fixture] press " + Math.round(mouse.x) + " " + Math.round(mouse.y))
            }

            Component.onCompleted: console.log("[rv-fixture] mapped " + panel.modelData.name)
        }
    }
}
