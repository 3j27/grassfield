// Part of tests/compositor/click_focus.sh (NESTED only): a small layer surface of another client with keyboard interactivity
// on_demand (namespace click-focus-fixture, Top layer, on the output named by GF_CF_OUTPUT), as a third-party panel or
// launcher has. A click on it gives it the keyboard while Hyprland still counts its last window as its focused window: the
// state in which a click on that window did nothing before grassfield-compositor 0.8.1 (docs/specs/compositor.md FR30 (d)).
// Every key it receives is logged ("[cf-fixture] key <text>"), its mapping too ("[cf-fixture] mapped <output>").
// Run: WAYLAND_DISPLAY=<nested> GF_CF_OUTPUT=<output> qs -p <this dir>
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string outputName: {
        const raw = Quickshell.env("GF_CF_OUTPUT") ?? "";
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
                right: true
            }
            // qmllint disable unqualified unresolved-type
            margins.top: 300
            margins.right: 40
            // qmllint enable unqualified unresolved-type
            implicitWidth: 220
            implicitHeight: 120
            exclusionMode: ExclusionMode.Ignore
            color: "#884422"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            WlrLayershell.namespace: "click-focus-fixture"

            Item {
                anchors.fill: parent
                focus: true
                Keys.onPressed: event => console.log("[cf-fixture] key " + event.text)
            }

            Component.onCompleted: console.log("[cf-fixture] mapped " + panel.modelData.name)
        }
    }
}
