pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.menubar
import qs.services

// Probe of tests/security/theme_icon_files.sh, part 5 on a PRIVATE bus (review of 423766f, major 2): the review's hostile
// StatusNotifierItems (fake_sni.py, each titled with its case) register with Quickshell's watcher; the REAL TrayHost
// lists them and the REAL TrayButton draws them. For each, once PROBE_COUNT items are listed and every copy answered:
// "probe: <title> class=<copy|pixmap|none|other:...> status=<n>". Then a control icon must load and the probe must exit.
ShellRoot {
    id: root

    readonly property int expected: Number(Quickshell.env("PROBE_COUNT"))
    property int waited: 0
    property string phase: "items"

    QtObject {
        id: fakeBar
        function isOpen(kind: string): bool {
            return false;
        }
        function openTray(button: var, item: var): void {
        }
        function hoverSwitchTray(button: var, item: var): void {
        }
    }

    function iconImage(button: var): var {
        const walk = node => {
            if (node.objectName === "menubar-tray-icon")
                return node;
            for (const child of node.children) {
                const found = walk(child);
                if (found)
                    return found;
            }
            return null;
        };
        return walk(button);
    }

    // "generic": nothing of the app's (the fallback, application-x-executable, which has no file offscreen).
    function classOf(source: string): string {
        if (source === "" || source === "image://icon/application-x-executable")
            return "generic";
        if (source.startsWith("file://") && source.indexOf("/grassfield-icons-") > 0 && source.endsWith(".png"))
            return "copy";
        if (source.startsWith("image://qspixmap/"))
            return "pixmap";
        return "other:" + source;
    }

    FloatingWindow {
        visible: true
        implicitWidth: 600
        implicitHeight: 80

        Row {
            Repeater {
                id: slots
                model: TrayHost.items

                TrayButton {
                    required property var modelData
                    item: modelData
                    bar: fakeBar
                }
            }
        }

        Image {
            id: control
            y: 40
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(64, 64)
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "items") {
                const pending = Object.keys(ThemeIcons.copies).some(k => ThemeIcons.copies[k].state === "pending");
                // TrayButton's Image loads asynchronously: a copy that answered can still be loading (status 2). Record
                // only once none is (the same 25 s bound; a load that never ends still shows as status 2).
                let loading = false;
                for (let i = 0; i < slots.count; i++) {
                    const image = root.iconImage(slots.itemAt(i));
                    if (image && image.status === Image.Loading)
                        loading = true;
                }
                if ((slots.count < root.expected || pending || loading || root.waited < 1500) && root.waited < 25000)
                    return;
                console.log("probe: items=" + slots.count);
                for (let i = 0; i < slots.count; i++) {
                    const button = slots.itemAt(i);
                    const image = root.iconImage(button);
                    console.log("probe: " + button.item.title + " class=" + root.classOf(image ? image.source.toString() : "no-image") + " status=" + (image ? image.status : -1));
                }
                ThemeIcons.source("ctl");
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
                console.log("probe: done ctl=" + control.status);
                Qt.exit(0);
            }
        }
    }
}
