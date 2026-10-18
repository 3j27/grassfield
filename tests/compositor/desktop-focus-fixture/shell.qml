// Part of tests/compositor/desktop_focus.sh (NESTED only): stands in for the shell's desktop surface as it behaves
// when the compositor advertises "desktop-focus" (docs/specs/desktop.md "Compositor focus policy"), plus a Dock and a
// menu bar, on every output:
//   - desktop: full-screen layer surface, namespace grassfield-desktop-icons (what the plugin matches), keyboard
//     interactivity None until a left press, then OnDemand; back to None when it loses the keyboard. No kicker surface,
//     no drop on pointer leave (those are the shell's workarounds for Hyprland without the plugin). A right press opens a
//     PopupWindow menu with a keyboard grab (Esc closes it). Placed on the Bottom layer so that the running shell's own
//     Background desktop and Bottom widgets (mapped earlier) never take the test's presses; the plugin matches the
//     namespace on any layer.
//   - Dock and menu bar: Top-layer surfaces with keyboard None, namespaces grassfield-dock / grassfield-menubar.
// Every key, press and keyboard enter/leave is logged with the output name, so the script can tell who got each key.
// Input (validated): GF_DF_OUTPUTS (comma-separated output names; default: every output).
// Run: WAYLAND_DISPLAY=<nested> qs -p <this dir>
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property var outputNames: {
        const raw = Quickshell.env("GF_DF_OUTPUTS") ?? "";
        return raw.split(",").filter(n => /^[A-Za-z0-9._-]{1,32}$/.test(n));
    }
    readonly property var screensUsed: Quickshell.screens.filter(s => root.outputNames.length === 0 || root.outputNames.indexOf(s.name) !== -1)

    Component.onCompleted: console.log("[df-fixture] outputs " + root.screensUsed.map(s => s.name).join(","))

    Variants {
        model: root.screensUsed

        Scope {
            id: perScreen

            required property ShellScreen modelData

            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: desktop

                property bool armed: false
                property bool hadKeys: false
                property real menuX: 0
                property real menuY: 0
                readonly property bool hasKeys: desktopItem.Window.active

                screen: perScreen.modelData
                anchors {
                    top: true
                    bottom: true
                    left: true
                    right: true
                }
                exclusionMode: ExclusionMode.Ignore
                color: Qt.rgba(0.12, 0.30, 0.22, 1)
                WlrLayershell.layer: WlrLayer.Bottom
                WlrLayershell.keyboardFocus: desktop.armed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
                WlrLayershell.namespace: "grassfield-desktop-icons"

                onHasKeysChanged: {
                    console.log("[df-fixture] desktop-keys " + perScreen.modelData.name + " " + desktop.hasKeys);
                    if (desktop.hasKeys)
                        desktop.hadKeys = true;
                    else if (desktop.hadKeys) {
                        desktop.hadKeys = false;
                        desktop.armed = false;
                    }
                }
                onArmedChanged: console.log("[df-fixture] desktop-interactivity " + perScreen.modelData.name + " " + (desktop.armed ? "ondemand" : "none"))

                // Never OnDemand while idle (it would take the keyboard on hover): give up if it was not granted.
                Timer {
                    id: armTimeout
                    interval: 400 // Tokens.desktopIconFocusArmMs
                    onTriggered: if (!desktop.hasKeys)
                        desktop.armed = false
                }

                Item {
                    id: desktopItem
                    anchors.fill: parent
                    focus: true
                    Keys.onPressed: event => {
                        console.log("[df-fixture] desktop-key " + perScreen.modelData.name + " " + (event.text.length === 1 ? event.text : "#" + event.key));
                        event.accepted = true;
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: mouse => {
                        console.log("[df-fixture] desktop-press " + perScreen.modelData.name + " " + (mouse.button === Qt.RightButton ? "right" : "left"));
                        if (mouse.button === Qt.LeftButton) {
                            desktop.armed = true;
                            armTimeout.restart();
                        } else {
                            desktop.menuX = mouse.x;
                            desktop.menuY = mouse.y;
                            menu.visible = true;
                        }
                    }
                }

                PopupWindow {
                    id: menu

                    anchor.window: desktop
                    anchor.rect: Qt.rect(desktop.menuX, desktop.menuY, 1, 1)
                    implicitWidth: 160
                    implicitHeight: 80
                    grabFocus: true
                    color: Qt.rgba(0.9, 0.9, 0.9, 1)
                    onVisibleChanged: console.log("[df-fixture] menu " + perScreen.modelData.name + " " + (menu.visible ? "open" : "closed"))

                    Item {
                        anchors.fill: parent
                        focus: true
                        Keys.onPressed: event => {
                            console.log("[df-fixture] menu-key " + perScreen.modelData.name + " " + (event.text.length === 1 ? event.text : "#" + event.key));
                            if (event.key === Qt.Key_Escape)
                                menu.visible = false;
                            event.accepted = true;
                        }
                    }
                }
            }

            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: dock

                screen: perScreen.modelData
                anchors.bottom: true
                implicitWidth: 400
                implicitHeight: 80
                exclusionMode: ExclusionMode.Ignore
                color: Qt.rgba(0.85, 0.85, 0.9, 1)
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                WlrLayershell.namespace: "grassfield-dock"

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPressed: console.log("[df-fixture] dock-press " + perScreen.modelData.name)
                    onContainsMouseChanged: console.log("[df-fixture] dock-hover " + perScreen.modelData.name + " " + containsMouse)
                }
            }

            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: menubar

                screen: perScreen.modelData
                anchors {
                    top: true
                    left: true
                    right: true
                }
                implicitHeight: 30
                exclusionMode: ExclusionMode.Ignore
                color: Qt.rgba(0.95, 0.95, 0.95, 1)
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                WlrLayershell.namespace: "grassfield-menubar"

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onPressed: console.log("[df-fixture] menubar-press " + perScreen.modelData.name)
                    onContainsMouseChanged: console.log("[df-fixture] menubar-hover " + perScreen.modelData.name + " " + containsMouse)
                }
            }
        }
    }
}
