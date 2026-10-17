pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Grassfield.Ui
import "Placements.js" as Placements

// Widget placements (widgets/1, docs/specs/widgets.md): where each widget sits, in the Notification
// Center and on the desktop, persisted in $GRASSFIELD_STATE_HOME (dev) or $XDG_STATE_HOME/grassfield
// as widgets.json (directory 0700, file 0600, written atomically, version 1). Ids that are not in
// the registry, and sizes a widget does not offer, are dropped when the file is read. A file that
// cannot be parsed is copied to widgets.json.bak before the next write replaces it.
Singleton {
    id: root

    property var placements: Placements.empty()
    readonly property var center: placements.center
    readonly property var desktop: placements.desktop
    property bool loaded: false

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: {
        const dev = Quickshell.env("GRASSFIELD_STATE_HOME");
        if (dev)
            return dev;
        const xdg = Quickshell.env("XDG_STATE_HOME");
        return (xdg ? xdg : home + "/.local/state") + "/grassfield";
    }
    readonly property string path: stateDir + "/widgets.json"

    // Battery widget availability: hidden from the gallery on a machine without a battery.
    readonly property var battery: UPower.displayDevice
    readonly property bool hasBattery: battery !== null && battery.isPresent && battery.isLaptopBattery

    function available(id: string): bool {
        return id !== "battery" || hasBattery;
    }

    // Grid of a screen: {cols, rows, x0, y0, cell, gap} in screen px.
    function gridFor(screen: var): var {
        const cell = Tokens.widgetCell;
        const gap = Tokens.widgetGap;
        const margin = Tokens.widgetDesktopMargin;
        const g = Placements.gridSize(screen.width, screen.height - Tokens.menubarHeight, cell, gap, margin);
        return {
            cols: g.cols,
            rows: g.rows,
            x0: margin,
            y0: Tokens.menubarHeight + margin,
            cell: cell,
            gap: gap
        };
    }

    function screenByName(name: string): var {
        for (const s of Quickshell.screens) {
            if (s.name === name)
                return s;
        }
        return null;
    }

    // ---- changes (each one saves) ---------------------------------------------------------------

    function apply(next: var): void {
        placements = next;
        saveTimer.restart();
    }

    function addCenter(id: string, size: string): void {
        if (available(id))
            apply(Placements.addCenter(placements, id, size));
    }

    // Returns false when the desktop of that screen has no room left.
    function addDesktop(id: string, size: string, screenName: string): bool {
        const screen = screenByName(screenName);
        if (!screen || !available(id))
            return false;
        const grid = gridFor(screen);
        const next = Placements.addDesktop(placements, id, size, screenName, grid.cols, grid.rows);
        if (next.desktop.length === placements.desktop.length)
            return false;
        apply(next);
        return true;
    }

    function remove(uid: string): void {
        apply(Placements.remove(placements, uid));
    }

    function setSize(uid: string, size: string): void {
        const entry = placements.desktop.find(e => e.uid === uid);
        const screen = entry ? screenByName(entry.screen) : null;
        const grid = screen ? gridFor(screen) : null;
        apply(Placements.setSize(placements, uid, size, grid));
    }

    function moveDesktop(uid: string, col: int, row: int, screenName: string): void {
        const screen = screenByName(screenName);
        if (!screen)
            return;
        const grid = gridFor(screen);
        apply(Placements.moveDesktop(placements, uid, {
            col: col,
            row: row
        }, grid.cols, grid.rows));
    }

    // ---- persistence ----------------------------------------------------------------------------

    function load(text: string): void {
        const r = Placements.parse(text);
        if (!r.ok) {
            console.warn("widgets: " + path + " is not a version 1 widgets file; keeping a copy as widgets.json.bak and starting empty");
            Quickshell.execDetached(["cp", "-p", path, path + ".bak"]);
        }
        placements = r.state;
        loaded = true;
    }

    Component.onCompleted: prepare.running = true

    // The directory and the file get restrictive modes before the first write (FileView cannot set
    // modes and its atomic write keeps the mode of an existing target).
    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.path]
        onRunningChanged: {
            if (!running)
                file.path = root.path;
        }
    }

    FileView {
        id: file
        printErrors: false
        atomicWrites: true
        onLoaded: root.load(file.text())
        onLoadFailed: root.loaded = true
    }

    Timer {
        id: saveTimer
        interval: 300
        onTriggered: {
            if (root.loaded)
                file.setText(Placements.serialize(root.placements));
        }
    }
}
