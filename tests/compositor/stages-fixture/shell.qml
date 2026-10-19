// Part of tests/compositor/stages.sh (NESTED only): stands in for the shell's Stages strip (docs/specs/stages.md "Shell
// contract") on one output:
//   - strip: a Top-layer surface anchored to the left edge, namespace grassfield-stages (what the plugin requires before
//     it draws thumbnails), keyboard None, transparent (the plugin draws the windows' thumbnails under it, in the window
//     layer), whole-surface input; tile outlines only, so screenshots show where the tiles are. Every press is logged in
//     layout coordinates, so the script can map it to a tile as the shell would.
//   - exclusive (GF_STAGES_ROLE=exclusive, a second instance): an Overlay-layer surface with Exclusive keyboard
//     interactivity in the top-right corner (what the shell's overview chrome or Search is to Hyprland), logging every key
//     it receives; the script ends it by killing the process (the surface unmaps).
//   - popup (GF_STAGES_ROLE=popup, another instance): an app window (xdg toplevel, 600x400) whose click opens a menu (an
//     xdg_popup with a grab, as an app menu); it logs the menu opening and closing and every key the window and the menu
//     receive.
//   - polkit (GF_STAGES_ROLE=polkit, another instance): what the shell's authentication dialog is to Hyprland
//     (shell/security/polkit/AuthAgent.qml: a full-output Overlay-layer surface with Exclusive keyboard interactivity and a
//     password field). It logs every key the field receives (test text only, never a real password). Escape releases it
//     as the dialog does when it ends: the keyboard interactivity goes to None first, the surface unmaps 400 ms later.
// Input (validated): GF_STAGES_OUTPUT (output name, required), GF_STAGES_TILES (JSON array of {x,y,w,h} in layout
// coordinates, at most 8), GF_STAGES_STRIP (JSON {x,y,w,h}: the strip surface box in layout coordinates), GF_STAGES_ROLE
// ("strip", the default, "exclusive", "popup" or "polkit").
// Run: WAYLAND_DISPLAY=<nested> qs -p <this dir>
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string outputName: {
        const raw = Quickshell.env("GF_STAGES_OUTPUT") ?? "";
        return /^[A-Za-z0-9._-]{1,32}$/.test(raw) ? raw : "";
    }
    readonly property var strip: {
        try {
            const s = JSON.parse(Quickshell.env("GF_STAGES_STRIP") ?? "{}");
            return [s.x, s.y, s.w, s.h].every(v => typeof v === "number" && isFinite(v)) ? s : null;
        } catch (e) {
            return null;
        }
    }
    readonly property var tiles: {
        try {
            const t = JSON.parse(Quickshell.env("GF_STAGES_TILES") ?? "[]");
            return Array.isArray(t) ? t.slice(0, 8).filter(r => [r.x, r.y, r.w, r.h].every(v => typeof v === "number" && isFinite(v))) : [];
        } catch (e) {
            return [];
        }
    }
    readonly property var screen: Quickshell.screens.find(s => s.name === root.outputName) ?? null
    readonly property string role: {
        const raw = Quickshell.env("GF_STAGES_ROLE") ?? "";
        return raw === "exclusive" || raw === "popup" || raw === "polkit" ? raw : "strip";
    }
    // polkit role: the dialog holds the keyboard until Escape (then None, and unmapped 400 ms later).
    property bool polkitHeld: true
    property bool polkitShown: true

    Component.onCompleted: console.log("[stages-fixture] output " + (root.screen ? root.screen.name + " found" : root.outputName + " missing") + ", " + root.tiles.length + " tile(s), role " + root.role)

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: stripWindow

        visible: root.role === "strip" && root.screen !== null && root.strip !== null
        screen: root.screen
        anchors {
            top: true
            left: true
        }
        // qmllint disable unqualified unresolved-type
        margins.top: root.strip && root.screen ? root.strip.y - root.screen.y : 0
        margins.left: root.strip && root.screen ? root.strip.x - root.screen.x : 0
        // qmllint enable unqualified unresolved-type
        implicitWidth: root.strip ? root.strip.w : 1
        implicitHeight: root.strip ? root.strip.h : 1
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-stages"

        Repeater {
            model: root.tiles

            Rectangle {
                required property var modelData
                x: modelData.x - root.strip.x
                y: modelData.y - root.strip.y
                width: modelData.w
                height: modelData.h
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.5)
                radius: 10
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onPressed: mouse => console.log("[stages-fixture] press " + Math.round(root.strip.x + mouse.x) + " " + Math.round(root.strip.y + mouse.y))
        }
    }

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: exclusiveWindow

        visible: root.role === "exclusive" && root.screen !== null
        screen: root.screen
        anchors {
            top: true
            right: true
        }
        // qmllint disable unqualified unresolved-type
        margins.top: 60
        margins.right: 40
        // qmllint enable unqualified unresolved-type
        implicitWidth: 360
        implicitHeight: 120
        exclusionMode: ExclusionMode.Ignore
        color: Qt.rgba(0.2, 0.3, 0.6, 0.85)
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "grassfield-stages-test-exclusive"
        Component.onCompleted: if (visible) console.log("[stages-fixture] exclusive surface shown")
        onVisibleChanged: if (visible) console.log("[stages-fixture] exclusive surface shown")

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => console.log("[stages-fixture] key " + event.text)
        }
    }

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: polkitWindow

        visible: root.role === "polkit" && root.screen !== null && root.polkitShown
        screen: root.screen
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: Qt.rgba(0, 0, 0, 0.25)
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.polkitHeld ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-stages-test-polkit"
        Component.onCompleted: if (visible) console.log("[stages-fixture] polkit dialog shown")

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: 160
            radius: 14
            color: "#2b2f3a"

            TextInput {
                id: passwordField

                anchors.centerIn: parent
                width: 300
                focus: true
                color: "#ffffff"
                echoMode: TextInput.Password
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        event.accepted = true;
                        root.polkitHeld = false;
                        console.log("[stages-fixture] polkit released");
                        polkitHide.start();
                        return;
                    }
                    console.log("[stages-fixture] polkit key " + event.text);
                }
            }
        }

        Timer {
            id: polkitHide

            interval: 400
            onTriggered: {
                root.polkitShown = false;
                console.log("[stages-fixture] polkit hidden");
            }
        }
    }

    // qmllint disable uncreatable-type
    FloatingWindow {
        // qmllint enable uncreatable-type
        id: appWindow

        visible: root.role === "popup"
        implicitWidth: 600
        implicitHeight: 400
        color: "#334455"
        title: "stages-popup"
        Component.onCompleted: if (visible) console.log("[stages-fixture] popup app shown")

        MouseArea {
            anchors.fill: parent
            onClicked: mouse => {
                console.log("[stages-fixture] app click " + Math.round(mouse.x) + " " + Math.round(mouse.y));
                appMenu.visible = true;
            }
        }
        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => console.log("[stages-fixture] app key " + event.text)
        }

        PopupWindow {
            id: appMenu

            anchor.window: appWindow
            anchor.rect.x: 40
            anchor.rect.y: 40
            implicitWidth: 260
            implicitHeight: 200
            color: "#dd2222"
            grabFocus: true
            visible: false
            onVisibleChanged: {
                console.log("[stages-fixture] menu " + (visible ? "open" : "closed"));
                if (visible)
                    menuKeys.forceActiveFocus();
            }

            Item {
                id: menuKeys

                anchors.fill: parent
                focus: true
                Keys.onPressed: event => console.log("[stages-fixture] menu key " + event.text)
            }
        }
    }
}
