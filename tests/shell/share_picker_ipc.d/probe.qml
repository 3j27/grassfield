pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ADR-0035 D-6: the shell side of the screen-sharing picker under the real Quickshell (tests/shell/share_picker_ipc.sh drives
// it through `qs ipc` and the stand-in). Loads SharePicker (IPC target picker) and prints "picker-probe: ready <displays>".
// The Overlay is not loaded (no layer shell offscreen): the panel's popup kind is set, nothing is drawn. Test-only target
// "probe": the session's lock as shell.qml's Binding sets it, and another popup in the panel's place.
ShellRoot {
    Component.onCompleted: console.log("picker-probe: ready " + JSON.stringify(SharePicker.outputs()) + " " + (SharePicker.current === null ? "idle" : "open"))

    IpcHandler {
        target: "probe"

        function lock(on: string): string {
            SessionState.locked = on === "on";
            return "ok";
        }

        function popup(kind: string): string {
            Popups.openCentered(kind, {}, "");
            return Popups.kind;
        }
    }
}
