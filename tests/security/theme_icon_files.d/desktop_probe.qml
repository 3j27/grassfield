pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.launchpad
import qs.services

// Probe of tests/security/theme_icon_files.sh, part 3 (review of eee45cc): applications whose Icon= names a FIFO, as a
// path or as a theme name, in a scratch applications directory. Real Launchpad cells (AppsCell, which loads
// ThemeIcons.appIcon) are made for the four scratch entries; the Apps prewarm list (Apps.listedIconSources) is read too.
// Then a control icon is loaded: its Image only becomes Ready when the one image loader never stalled. Prints one
// "probe:" line per entry and a "probe: done" line, then exits.
ShellRoot {
    id: root

    readonly property var ids: ["gf-fifo-path", "gf-fifo-name", "gf-ok-path", "gf-ok-name"]
    property var entries: ({})
    property var cells: []
    property int waited: 0
    property string phase: "entries"

    function entryFor(id: string): var {
        for (const e of DesktopEntries.applications.values) {
            if (e.id === id || e.id === id + ".desktop")
                return e;
        }
        return null;
    }

    function settled(): bool {
        for (const id of ids) {
            const v = ThemeIcons.verdicts[ThemeIcons.keyOf(entries[id].icon)];
            if (v === undefined || v === "pending")
                return false;
        }
        return true;
    }

    // The Apps singleton (prewarm list) starts now, as in the shell (the menu bar hosts the prewarm).
    Component.onCompleted: console.info("desktop probe: apps revision " + Apps.revision)

    function prewarmed(id: string): bool {
        return Apps.listedIconSources.indexOf(ThemeIcons.appIcon(entries[id].icon, "application-x-executable")) >= 0;
    }

    Component {
        id: cellComponent
        AppsCell {}
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 600
        implicitHeight: 160

        Row {
            id: row
        }

        Image {
            id: control
            y: 120
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(64, 64)
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "entries") {
                const found = {};
                for (const id of root.ids) {
                    const e = root.entryFor(id);
                    if (e)
                        found[id] = e;
                }
                if (Object.keys(found).length < root.ids.length && root.waited < 10000)
                    return;
                root.entries = found;
                if (Object.keys(found).length < root.ids.length) {
                    console.log("probe: entries missing: " + root.ids.filter(id => !found[id]).join(","));
                    Qt.exit(1);
                    return;
                }
                const list = [];
                for (const id of root.ids)
                    list.push(cellComponent.createObject(row, {info: {key: id, id: id, name: id, rec: {icon: found[id].icon}}}));
                root.cells = list;
                root.phase = "verdicts";
                root.waited = 0;
            } else if (root.phase === "verdicts") {
                // The cells' bindings asked; wait for every verdict, then a second for any stalled read to begin.
                const ready = root.settled() && root.prewarmed("gf-ok-path") && root.prewarmed("gf-ok-name");
                if ((!ready || root.waited < 1000) && root.waited < 15000)
                    return;
                for (const id of root.ids) {
                    const icon = root.entries[id].icon;
                    console.log("probe: " + id + " verdict=" + ThemeIcons.verdicts[ThemeIcons.keyOf(icon)] + " source=" + ThemeIcons.appIcon(icon, "")
                        + " prewarmed=" + root.prewarmed(id));
                }
                ThemeIcons.check("ctl", false);
                root.phase = "control";
                root.waited = 0;
            } else if (root.phase === "control") {
                const c = ThemeIcons.source("ctl");
                if (c === "" && root.waited < 10000)
                    return;
                control.source = c;
                root.phase = "loaded";
                root.waited = 0;
            } else if (root.phase === "loaded") {
                if (control.status !== Image.Ready && root.waited < 5000)
                    return;
                stop();
                console.log("probe: done ctl=" + control.status);
                Qt.exit(0);
            }
        }
    }
}
