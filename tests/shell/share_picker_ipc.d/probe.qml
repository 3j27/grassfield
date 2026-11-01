pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.overlay
import qs.services

// ADR-0035 D-6: the shell side of the screen-sharing picker under the real Quickshell (tests/shell/share_picker_ipc.sh drives
// it through `qs ipc` and the stand-in). Loads SharePicker (IPC target picker) and prints "picker-probe: ready <displays>".
// The Overlay is not loaded (no layer shell offscreen): the panel's popup kind is set, and the panel itself is loaded as the
// Overlay loads it (a Loader per opening, here in no window: nothing is drawn). Test-only target "probe": the session's lock as
// shell.qml's Binding sets it, another popup in the panel's place, and the panel's privacy defaults as it opened.
ShellRoot {
    id: probe

    // The panel's state when the Loader made it: Remember this choice and the arming (owner decision Q14, ADR-0035 7-8).
    property var atOpen: null

    function find(item: Item, name: string): Item {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = probe.find(item.children[i], name);
            if (found !== null)
                return found;
        }
        return null;
    }

    function panelState(): var {
        const p = panel.item as SharePickerPanel;
        if (p === null)
            return null;
        const box = probe.find(p, "sharepicker-remember") as CheckBox;
        const share = probe.find(p, "sharepicker-share") as Button;
        return {
            remember: p.remember,
            armed: p.armed,
            box: box !== null ? box.checked : null,
            share: share !== null ? share.enabled : null
        };
    }

    Component.onCompleted: console.log("picker-probe: ready " + JSON.stringify(SharePicker.outputs()) + " " + (SharePicker.current === null ? "idle" : "open"))

    Loader {
        id: panel
        active: Popups.kind === "sharePicker"
        sourceComponent: SharePickerPanel {}
        onLoaded: probe.atOpen = probe.panelState()
        onActiveChanged: {
            if (!active)
                probe.atOpen = null;
        }
    }

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

        // {atOpen, now}: the panel's Remember this choice (its property and its box), its arming and its Share button, as the
        // panel opened and now; "none" while no panel is loaded.
        function panel(): string {
            return probe.atOpen === null ? "none" : JSON.stringify({
                atOpen: probe.atOpen,
                now: probe.panelState()
            });
        }
    }
}
