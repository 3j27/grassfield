// Part of tests/compositor/overview_focus.sh (NESTED only): stands in for the shell's Overview chrome on two outputs and for
// a polkit-like dialog, to verify where the keyboard goes when the Overview closes (docs/specs/overview.md "Close focus"):
//   - chrome A / chrome B: one per output (GF_OF_OUTPUT_A, GF_OF_OUTPUT_B), namespace grassfield-overview, Overlay layer,
//     full output, whole-surface input, a light dim. While "open" both are keyboard Exclusive (as the shell's chromes are:
//     Hyprland then gives the keyboard to ONE of them); a release drops them to None in the order asked, each commit on its
//     own, and they stay mapped like the shell's persistent chromes, or unmap after a delay. Every key and press they get
//     is logged with the output.
//   - polkit: what the shell's authentication dialog is to Hyprland (a full-output Overlay surface with Exclusive keyboard
//     interactivity and a password field, shell/security/polkit/AuthAgent.qml) on one output; it logs every key its field
//     gets (the test types letters only, never a real password). Released as the dialog ends: keyboard None, unmapped
//     300 ms later.
// Driven over Quickshell IPC, target "ovf": open(), holder() (the output whose chrome holds the keyboard, "" for none),
// release(order, gapMs, unmapMs) with order "holder-first" | "holder-last" | "together" (gapMs between the two commits,
// unmapMs after the last one, -1: stay mapped), polkit(output), polkitRelease(), status(); close(request, order, gapMs,
// unmapMs) and closeWithPolkit(request, output, order, gapMs, polkitMs): the Overview's own sequence from one place, as
// the shell does it (the overview_focus request dispatched, the release 30 ms later, the dialog released polkitMs after
// the request), so that every delay is timed from the request: a `qs ipc` call takes 80 to 200 ms to arrive on a loaded
// host, and a release sent as a second call made the remaining chrome's hold end past the plugin's 1000-ms bound
// (overview_focus.sh case 10 had 19 ms of slack in the passing run of 2026-10-23, and failed by 28 ms on 2026-10-24).
// Input (validated): GF_OF_OUTPUT_A, GF_OF_OUTPUT_B (output names). Run: WAYLAND_DISPLAY=<nested> qs -p <this dir>
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    function outputFrom(name: string): string {
        const raw = Quickshell.env(name) ?? "";
        return /^[A-Za-z0-9._-]{1,32}$/.test(raw) ? raw : "";
    }

    readonly property string outA: outputFrom("GF_OF_OUTPUT_A")
    readonly property string outB: outputFrom("GF_OF_OUTPUT_B")
    readonly property var screenA: Quickshell.screens.find(s => s.name === root.outA) ?? null
    readonly property var screenB: Quickshell.screens.find(s => s.name === root.outB) ?? null

    property bool shownA: false
    property bool shownB: false
    property bool exclusiveA: false
    property bool exclusiveB: false
    property bool activeA: false
    property bool activeB: false
    // The release in progress: which chrome goes second, and whether the chromes unmap afterwards.
    property string secondOut: ""
    property int unmapAfterMs: -1

    property string polkitOut: ""
    readonly property var polkitScreen: Quickshell.screens.find(s => s.name === root.polkitOut) ?? null
    property bool polkitHeld: false
    property bool polkitShown: false

    function log(text: string): void {
        console.log("[ovf-fixture] " + text);
    }

    function setExclusive(out: string, on: bool): void {
        if (out === outA)
            exclusiveA = on;
        else if (out === outB)
            exclusiveB = on;
        log("chrome " + out + " keyboard " + (on ? "exclusive" : "none"));
    }

    // The close sequence (close / closeWithPolkit): what the release does once the request is out.
    property string pendingOrder: ""
    property int pendingGapMs: 0
    property int pendingUnmapMs: -1
    property string pendingPolkitOut: ""

    // The request as the shell sends it (the same Lua call as overview_focus.sh's request()); false when it could break out
    // of the Lua long string or is not one line of at most 1 KiB.
    function dispatchRequest(request: string): bool {
        if (typeof request !== "string" || request.length === 0 || request.length > 1024 || request.indexOf("]]") >= 0 || /[\r\n]/.test(request))
            return false;
        Hyprland.dispatch("function() local p = hl.plugin and hl.plugin.grassfield; if p and p.overview_focus then p.overview_focus([[" + request + "]]) end end");
        log("request dispatched");
        return true;
    }

    function released(): void {
        if (unmapAfterMs < 0)
            return;
        unmapTimer.interval = Math.max(0, unmapAfterMs);
        unmapTimer.restart();
    }

    Component.onCompleted: log("outputs " + outA + (screenA ? " found" : " NOT FOUND") + " " + outB + (screenB ? " found" : " NOT FOUND"))

    Timer {
        id: secondTimer
        onTriggered: {
            root.setExclusive(root.secondOut, false);
            root.released();
        }
    }

    Timer {
        id: unmapTimer
        onTriggered: {
            root.shownA = false;
            root.shownB = false;
            root.log("chromes unmapped");
        }
    }

    // The release of a close sequence, 30 ms after its request (the request reaches Hyprland first, as when the shell sends
    // it before releasing its chromes).
    Timer {
        id: closeTimer
        interval: 30
        onTriggered: {
            if (root.pendingPolkitOut !== "") {
                root.polkitOut = root.pendingPolkitOut;
                root.polkitHeld = true;
                root.polkitShown = true;
                root.log("polkit shown on " + root.polkitOut);
            }
            ipc.release(root.pendingOrder, root.pendingGapMs, root.pendingUnmapMs);
        }
    }

    // The dialog's end in closeWithPolkit, timed from the request.
    Timer {
        id: polkitEnd
        onTriggered: ipc.polkitRelease()
    }

    Timer {
        id: polkitHide
        interval: 300
        onTriggered: {
            root.polkitShown = false;
            root.log("polkit hidden");
        }
    }

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: chromeA

        visible: root.shownA && root.screenA !== null
        screen: root.screenA
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: Qt.rgba(0, 0, 0, 0.18)
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.exclusiveA ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-overview"

        Item {
            anchors.fill: parent
            focus: true
            readonly property bool held: Window.active
            onHeldChanged: {
                root.activeA = held;
                root.log("chrome " + root.outA + " active " + held);
            }
            Keys.onPressed: event => root.log("chrome key " + event.text + " on " + root.outA)
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: root.log("chrome press on " + root.outA)
        }
    }

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: chromeB

        visible: root.shownB && root.screenB !== null
        screen: root.screenB
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: Qt.rgba(0, 0, 0, 0.18)
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.exclusiveB ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-overview"

        Item {
            anchors.fill: parent
            focus: true
            readonly property bool held: Window.active
            onHeldChanged: {
                root.activeB = held;
                root.log("chrome " + root.outB + " active " + held);
            }
            Keys.onPressed: event => root.log("chrome key " + event.text + " on " + root.outB)
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: root.log("chrome press on " + root.outB)
        }
    }

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: polkitWindow

        visible: root.polkitShown && root.polkitScreen !== null
        screen: root.polkitScreen
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
        WlrLayershell.namespace: "grassfield-overview-focus-test-polkit"
        onVisibleChanged: root.log("polkit " + (visible ? "shown" : "unmapped"))

        Rectangle {
            anchors.centerIn: parent
            width: 420
            height: 160
            radius: 14
            color: "#2b2f3a"

            TextInput {
                anchors.centerIn: parent
                width: 300
                focus: true
                color: "#ffffff"
                echoMode: TextInput.Password
                Keys.onPressed: event => root.log("polkit key " + event.text)
            }
        }
    }

    IpcHandler {
        id: ipc

        target: "ovf"

        function open(): string {
            secondTimer.stop();
            unmapTimer.stop();
            root.shownA = true;
            root.shownB = true;
            root.setExclusive(root.outA, true);
            root.setExclusive(root.outB, true);
            return "ok";
        }

        function holder(): string {
            return root.activeA ? root.outA : (root.activeB ? root.outB : "");
        }

        // The holder is the chrome that holds the keyboard now (chrome A when none does).
        function release(order: string, gapMs: int, unmapMs: int): string {
            const holderOut = root.activeB && !root.activeA ? root.outB : root.outA;
            const otherOut = holderOut === root.outA ? root.outB : root.outA;
            root.unmapAfterMs = unmapMs;
            root.log("release " + order + " gap " + gapMs + " unmap " + unmapMs + " (holder " + holderOut + ")");
            if (order === "together") {
                root.exclusiveA = false;
                root.exclusiveB = false;
                root.log("chromes keyboard none together");
                root.released();
                return "ok";
            }
            const first = order === "holder-first" ? holderOut : otherOut;
            root.secondOut = first === holderOut ? otherOut : holderOut;
            root.setExclusive(first, false);
            secondTimer.interval = Math.max(0, gapMs);
            secondTimer.restart();
            return "ok";
        }

        function close(request: string, order: string, gapMs: int, unmapMs: int): string {
            if (!root.dispatchRequest(request))
                return "invalid request";
            root.pendingOrder = order;
            root.pendingGapMs = gapMs;
            root.pendingUnmapMs = unmapMs;
            root.pendingPolkitOut = "";
            closeTimer.restart();
            return "ok";
        }

        function closeWithPolkit(request: string, output: string, order: string, gapMs: int, polkitMs: int): string {
            if (!/^[A-Za-z0-9._-]{1,32}$/.test(output) || !root.dispatchRequest(request))
                return "invalid request";
            root.pendingOrder = order;
            root.pendingGapMs = gapMs;
            root.pendingUnmapMs = -1;
            root.pendingPolkitOut = output;
            closeTimer.restart();
            polkitEnd.interval = Math.max(closeTimer.interval + 1, polkitMs);
            polkitEnd.restart();
            return "ok";
        }

        function polkit(output: string): string {
            root.polkitOut = /^[A-Za-z0-9._-]{1,32}$/.test(output) ? output : "";
            root.polkitHeld = true;
            root.polkitShown = true;
            return root.polkitScreen ? "ok" : "no such output";
        }

        function polkitRelease(): string {
            root.polkitHeld = false;
            root.log("polkit released");
            polkitHide.restart();
            return "ok";
        }

        function status(): string {
            return JSON.stringify({
                a: {output: root.outA, shown: chromeA.visible, exclusive: root.exclusiveA, active: root.activeA},
                b: {output: root.outB, shown: chromeB.visible, exclusive: root.exclusiveB, active: root.activeB},
                polkit: {output: root.polkitOut, shown: polkitWindow.visible, exclusive: root.polkitHeld}
            });
        }
    }
}
