// The shell's Apps grid, offscreen: Quickshell's own DesktopEntries (the parser the grid uses), then the grid's rules exactly as
// shell/launchpad/AppsController.qml applies them: not noDisplay, not in the hidden list (hidden-entries.sh, passed in
// GF_HIDDEN, one id per line), then Model.disambiguate and Model.sortApps. Prints one "GRID|<id>|<name>" line per app.
// Run by tests/unit/files/apps_grid_vs_files.sh; never started without QT_QPA_PLATFORM=offscreen.
import QtQuick
import Quickshell
import "../../../../shell/launchpad/Model.js" as Model

ShellRoot {
    id: root
    property bool done: false

    function report(): void {
        if (root.done)
            return;
        root.done = true;
        const hidden = Model.parseHidden(Quickshell.env("GF_HIDDEN") ?? "");
        const raw = [];
        for (const e of DesktopEntries.applications.values) {
            console.log("RAW|" + e.id + "|" + (e.noDisplay ? "nodisplay" : "shown") + "|" + e.name);
            if (e.noDisplay || Model.isHidden(hidden, e.id))
                continue;
            raw.push({id: e.id, name: e.name, genericName: e.genericName, comment: e.comment});
        }
        for (const r of Model.sortApps(Model.disambiguate(raw)))
            console.log("GRID|" + r.id + "|" + r.name);
        console.log("DONE");
        Qt.quit();
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            settle.restart();
        }
    }

    // The list is read in the background: report once it has stopped changing (or after the longest wait).
    Timer {
        id: settle
        interval: 1500
        onTriggered: root.report()
    }

    Timer {
        interval: 20000
        running: true
        onTriggered: root.report()
    }
}
