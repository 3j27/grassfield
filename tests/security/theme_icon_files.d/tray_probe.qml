pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.menubar
import qs.services

// Probe of tests/security/theme_icon_files.sh, part 5 (review of 423766f, major 2: Quickshell resolved an app's
// IconThemePath and a path-like IconName itself, and a FIFO there stalled the image loader). The REAL TrayButton is
// given fake tray items whose `icon` is what Quickshell's SystemTrayItem reports for the review's hostile
// StatusNotifierItems (PROBE_ITEMS: "label=icon" lines; $S is the scratch tree):
//   themepath-fifo      image://icon/sni?path=$S/outside       (sni.png, hicolor/48x48/apps/sni.png, index.theme: FIFOs)
//   themepath-svgref    image://icon/snisvg?path=$S/outside    (a gzip SVG naming a FIFO)
//   themepath-reg       image://icon/sniok?path=$S/tp          (a regular PNG in the app's own theme folder)
//   themepath-dotdot    image://icon/sni?path=$S/tp/../outside
//   iconname-abs-fifo   image://icon/$S/outside/evil.png
//   iconname-traversal  image://icon/../../../../../../..$S/outside/evil
//   iconname-abs-reg    image://icon/$S/outside/good.png
//   pixmap              image://qspixmap/0/0                    (the IconPixmap pixels: passed as they are)
//   plain-user          image://icon/trayctl                    (a user-installed icon name)
// For each it prints the class of the source the button's Image got: "copy" (a PNG the shell made), "pixmap", "generic"
// (refused: the fallback icon), or "other:" and the source itself (a failure), and the Image's status once
// settled. Then a control icon must load (the image loader never stalled) and the probe must exit (the GUI thread
// never blocked). Prints "probe:" lines and "probe: done", then exits.
ShellRoot {
    id: root

    readonly property var items: Quickshell.env("PROBE_ITEMS").split("\n").filter(l => l.indexOf("=") > 0).map(l => ({label: l.slice(0, l.indexOf("=")), icon: l.slice(l.indexOf("=") + 1)}))
    property var buttons: []
    property int waited: 0
    property string phase: "settle"

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

    Component {
        id: itemComponent
        QtObject {
            property string icon: ""
            property string title: "Probe"
            property string tooltipTitle: ""
            property string id: "probe"
            property int status: 1
            property bool hasMenu: false
            property bool onlyMenu: false
            function activate(): void {
            }
            function secondaryActivate(): void {
            }
            function scroll(delta: int, horizontal: bool): void {
            }
        }
    }

    Component {
        id: buttonComponent
        TrayButton {}
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

    Component.onCompleted: {
        const made = [];
        for (const it of items) {
            const item = itemComponent.createObject(root, {icon: it.icon});
            made.push({label: it.label, button: buttonComponent.createObject(row, {item: item, bar: fakeBar})});
        }
        buttons = made;
    }

    FloatingWindow {
        visible: true
        implicitWidth: 600
        implicitHeight: 80

        Row {
            id: row
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
            if (root.phase === "settle") {
                // Every copy asked for answered, then a second more for a stalled read to begin.
                const pending = Object.keys(ThemeIcons.copies).some(k => ThemeIcons.copies[k].state === "pending");
                // The Images load asynchronously: an answered copy can still be loading (status 2); wait for none to be
                // (same 20 s bound: a load that never ends still shows as status 2).
                const loading = root.buttons.some(b => {
                    const image = root.iconImage(b.button);
                    return image && image.status === Image.Loading;
                });
                if ((pending || loading || root.waited < 1500) && root.waited < 20000)
                    return;
                for (const b of root.buttons) {
                    const image = root.iconImage(b.button);
                    const source = image ? image.source.toString() : "no-image";
                    console.log("probe: " + b.label + " class=" + root.classOf(source) + " status=" + (image ? image.status : -1));
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
