pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform

// ADR-0031: the displays are described once Hyprland answers `monitors`, even when the answer is later than the publish
// debounce (tests/shell/displays_publish.sh runs it against a fake Hyprland that answers after 400 ms). Prints
// "displays-publish: PASS" or the failure.
ShellRoot {
    id: root

    readonly property string statePath: Displays.statePath

    FileView {
        id: stateFile
        path: root.statePath
        printErrors: false
    }

    Timer {
        interval: 2500
        running: true
        onTriggered: {
            stateFile.reload();
            stateFile.waitForJob();
            let names = "";
            try {
                names = JSON.parse(stateFile.text()).monitors.map(m => m.name).join(",");
            } catch (e) {
                names = "(no file: " + e + ")";
            }
            console.log(names === "GF-1,GF-2" ? "displays-publish: PASS (" + names + ")" : "displays-publish: FAIL the file lists \"" + names + "\", not GF-1,GF-2");
            Qt.quit();
        }
    }
}
