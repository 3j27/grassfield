pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.services

// The exit cover (ADR-0040 ID-10, step 7): once Log Out, Restart or Shut Down has closed every window, the whole screen fades
// to the ground in one movement (session.exitFadeMs) and the session ends under it, instead of the menu bar, the Dock and the
// wallpaper vanishing one by one. The ground is the session's Hyprland background colour (Ground.accepted, ID-2: the shown
// wallpaper's ground once Hyprland accepted it as that colour; session.ground before), so the cover and what remains once the
// shell itself has stopped are the same colour on every output; the black that follows is the greeter's or the
// firmware's. packaging/bin/grassfield-session-end asks for it (`qs ipc call session cover`, which answers how many
// milliseconds the fade lasts) and waits for it, at most session.exitWaitMs; when the session then cannot be ended it lifts
// the cover (`qs ipc call session lift`). A cover the helper could not lift (it was killed) lifts by itself after
// session.exitCoverHoldMs: an exit that did not happen never leaves an opaque screen over the desktop (P-6). The fade is the
// shell's own (one owner of motion, ID-4): the compositor adds none (windows.lua, gf-exit-cover-no-anim). Reduce Motion caps
// it at motion.reducedMax (Appearance.duration).
Scope {
    id: root

    property bool shown: false
    readonly property int fadeMs: Appearance.duration(Tokens.sessionExitFadeMs)

    // The milliseconds the caller waits for the fade, never more than session.exitWaitMs. While the session is locked nothing
    // but the lock screen opens (GF-116; the integrator's review of e067f26f, NIT): the lock already covers every output, so
    // the cover stays down and the caller waits for nothing.
    function cover(): int {
        if (SessionState.refuses("exit cover"))
            return 0;
        if (!root.shown)
            console.info("grassfield-shell: exit cover shown");
        root.shown = true;
        hold.restart();
        return Math.min(root.fadeMs, Tokens.sessionExitWaitMs);
    }

    function lift(): void {
        if (root.shown)
            console.info("grassfield-shell: exit cover lifted");
        hold.stop();
        root.shown = false;
    }

    Timer {
        id: hold
        interval: Tokens.sessionExitCoverHoldMs
        onTriggered: {
            console.warn("grassfield-shell: the session was still there " + interval + " ms after the exit cover came up; cover lifted");
            root.lift();
        }
    }

    IpcHandler {
        target: "session"

        // `qs ipc call session cover`: the cover comes up on every output; the answer is the fade's length in milliseconds.
        function cover(): string {
            return String(root.cover());
        }

        // `qs ipc call session lift`: the session did not end; the desktop shows again at once.
        function lift(): string {
            root.lift();
            return "ok";
        }

        // Test hook (the nested pass): `qs ipc call session state` -> "shown" or "hidden", "" outside a dev session.
        function state(): string {
            if (!VisualFixtures.dev)
                return "";
            return root.shown ? "shown" : "hidden";
        }
    }

    Variants {
        model: root.shown ? Quickshell.screens : []

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            required property ShellScreen modelData

            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            anchors {
                left: true
                right: true
                top: true
                bottom: true
            }
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "grassfield-exit-cover"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            Rectangle {
                anchors.fill: parent
                color: Ground.accepted

                // Starts at 0 (`from`): the animation sets the opacity before the first frame.
                NumberAnimation on opacity {
                    from: 0
                    to: 1
                    duration: root.fadeMs
                }
            }
        }
    }
}
