// Part of tests/compositor/overview.sh (NESTED only): stands in for the shell's overview v2 surfaces to verify the
// layering and input contract of docs/specs/overview.md "v2" with real transformed windows:
//   - a backdrop on the Bottom layer (below windows, above the wallpaper and desktop icons on Background) that dims
//     the desktop and takes no input;
//   - a transparent chrome on the Overlay layer (namespace grassfield-overview, like the shell's) with a Spaces bar
//     placeholder and one label under each layout rect, holding the pointer (whole surface) and the keyboard
//     (exclusive). Every press and key it receives is logged, so the script can check that clicks never reach the
//     real (untransformed) windows.
// Input (validated, never trusted): GF_OVERVIEW_OUTPUT (output name), GF_OVERVIEW_TARGETS (JSON array of
// {"x","y","w","h","label"} in layout coordinates), GF_OVERVIEW_DIM (0..1).
// Run: WAYLAND_DISPLAY=<nested> qs -p <this dir>
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string outputName: /^[A-Za-z0-9._-]{1,32}$/.test(Quickshell.env("GF_OVERVIEW_OUTPUT") ?? "") ? Quickshell.env("GF_OVERVIEW_OUTPUT") : "GF-REF"
    readonly property real dim: {
        const d = Number(Quickshell.env("GF_OVERVIEW_DIM") ?? "0.35");
        return isFinite(d) ? Math.max(0, Math.min(1, d)) : 0.35;
    }
    readonly property var targets: {
        try {
            const list = JSON.parse(Quickshell.env("GF_OVERVIEW_TARGETS") ?? "[]");
            if (!Array.isArray(list))
                return [];
            return list.slice(0, 64).filter(t => [t.x, t.y, t.w, t.h].every(v => typeof v === "number" && isFinite(v))).map(t => ({
                        x: t.x,
                        y: t.y,
                        w: t.w,
                        h: t.h,
                        label: String(t.label ?? "").slice(0, 64)
                    }));
        } catch (e) {
            return [];
        }
    }
    readonly property var outputScreen: Quickshell.screens.find(s => s.name === root.outputName) ?? null

    Component.onCompleted: console.log("[overview-fixture] output " + root.outputName + (root.outputScreen ? " found" : " NOT FOUND") + ", " + root.targets.length + " target(s)")

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk, as in shell/overview); suppress just this.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: backdrop

        screen: root.outputScreen
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: Qt.rgba(0, 0, 0, root.dim)
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.namespace: "grassfield-overview-backdrop"
        mask: Region {}
    }

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: chrome

        screen: root.outputScreen
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "grassfield-overview"

        Rectangle {
            id: spacesBar

            x: 0
            y: 0
            width: chrome.width
            height: 96
            color: Qt.rgba(1, 1, 1, 0.18)

            Text {
                anchors.centerIn: parent
                text: "Spaces bar (fixture)"
                textFormat: Text.PlainText
                color: "white"
                font.pixelSize: 18
            }
        }

        Repeater {
            model: root.targets

            delegate: Text {
                required property var modelData

                x: modelData.x - (root.outputScreen ? root.outputScreen.x : 0)
                y: modelData.y + modelData.h - (root.outputScreen ? root.outputScreen.y : 0) + 10
                width: modelData.w
                horizontalAlignment: Text.AlignHCenter
                text: modelData.label
                textFormat: Text.PlainText
                color: "white"
                font.pixelSize: 16
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPressed: mouse => console.log("[overview-fixture] press " + Math.round(mouse.x) + " " + Math.round(mouse.y))
        }

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => console.log("[overview-fixture] key " + event.key)
        }
    }
}
