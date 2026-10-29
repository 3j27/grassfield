pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

// The Apps grid on its FIRST opening is where every later one puts it: as AppsWindow does, the items arrive and the cell pool is
// warmed while the window is hidden, then the opening calls toBeginning(); the first row must sit below the chips
// (contentY = -topMargin), not under them, and must stay there once the first frames are drawn (no jump). Run by
// scripts/dev/test.sh: `qs -p tests/shell/apps_grid_first` (offscreen); prints "apps-grid-first: PASS" or FAIL.
// AppsGrid.qml and AppsCell.qml are symlinks to shell/launchpad, next to links to the shell modules (as apps_panel_perf).
ShellRoot {
    id: root

    property var seen: []
    property int frames: 0
    property bool judged: false

    function items(): var {
        const out = [];
        for (let i = 0; i < 120; i++) {
            const rec = {id: "fake" + i + ".desktop", name: "App " + i, genericName: "", comment: "", keywords: [], icon: "application-x-executable"};
            out.push({key: "app:" + rec.id, id: rec.id, name: rec.name, rec: rec});
        }
        return out;
    }

    function finish(): void {
        const want = -grid.topMargin;
        const bad = root.seen.filter(y => Math.abs(y - want) > 0.5);
        console.info("apps-grid-first: contentY after the opening and at each frame:", root.seen.join(", "), "(wanted", want + ")");
        console.info(bad.length === 0 && root.seen.length > 0 ? "apps-grid-first: PASS" : "apps-grid-first: FAIL the first opening is not in place");
        Qt.quit();
    }

    FloatingWindow {
        id: win
        implicitWidth: 844
        implicitHeight: 560
        visible: false
        color: "black"

        // The symlinked component is resolved by Quickshell from this directory; qmllint cannot see it.
        // qmllint disable import unresolved-type missing-property unqualified
        AppsGrid {
            id: grid
            // As AppsWindow: below the chips, a margin above the first row, a bottom margin.
            y: 46
            width: parent.width
            height: parent.height - y
            topMargin: 38
            bottomMargin: 12
            cellWidth: width / 7
            cellHeight: 102
            items: []
            selectedIndex: -1
            ringVisible: false
        }
        // qmllint enable import unresolved-type missing-property unqualified

        Connections {
            target: win.visible ? grid.Window.window : null

            function onFrameSwapped(): void {
                root.seen.push(grid.contentY);
                root.frames++;
                // The first frame is drawn: judge it, and what a moment of later frames does to it (no jump).
                if (!settle.running && !root.judged)
                    settle.start();
            }
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => {
            // Idle time after the list is built, before the window is ever shown (AppsWindow.onItemsChanged).
            grid.items = root.items();
            grid.warmPool();
            Qt.callLater(() => {
                // The opening (AppsWindow.onShownChanged).
                win.visible = true;
                grid.toBeginning();
                root.seen.push(grid.contentY);
            });
        });
    }

    // A short wait after the first frame for the view to settle; the long timer below is only a safety net.
    Timer {
        id: settle
        interval: 400
        onTriggered: {
            root.judged = true;
            root.finish();
        }
    }

    Timer {
        interval: 15000
        running: true
        onTriggered: root.finish()
    }
}
