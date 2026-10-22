pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.menubar

// Body of tests/integration/tray_host.sh (named host.qml so the plain tests/shell/*/shell.qml loop skips it; run it through that
// script, which gives it a PRIVATE session bus). The real StatusNotifier host (TrayHost, Quickshell SystemTray) against test
// items (tests/fixtures/status-item.py): two items with the SAME id get two slots, a Passive one gets none, a status change
// shows it, the SNI calls and the DBusMenu rows and events arrive intact, and an item whose process dies leaves no slot.
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("GF_TEST_DIR")
    readonly property string fixture: Quickshell.env("GF_FIXTURE")
    property var failures: []
    property int stepIndex: 0
    property int waited: 0
    property var sniA: null
    property var sniB: null

    function check(name: string, ok: bool): void {
        if (ok)
            console.info("tray-test: ok " + name);
        else {
            console.warn("tray-test: FAIL " + name);
            failures.push(name);
        }
    }

    function byTitle(title: string): var {
        const all = TrayHost.items;
        for (let i = 0; i < all.length; i++) {
            if (all[i].title === title)
                return all[i];
        }
        return null;
    }

    component Fixture: Process {
        id: proc

        required property string name
        property var extra: []
        environment: ({GF_TEST_BUS: "1"})
        command: ["python3", "-I", root.fixture, "--log", root.dir + "/" + name + ".log", "--ready", root.dir + "/" + name + ".ready", "--set-status-file", root.dir + "/" + name + ".status"].concat(extra)
        stderr: StdioCollector {
            onStreamFinished: if (text !== "")
                console.warn("tray-test: fixture " + proc.name + ": " + text)
        }
    }

    Fixture {
        id: procA
        name: "a"
        extra: ["--id", "chrome_status_icon_1", "--title", "Item A"]
    }

    Fixture {
        id: procB
        name: "b"
        extra: ["--id", "chrome_status_icon_1", "--title", "Item B", "--only-menu"]
    }

    Fixture {
        id: procC
        name: "c"
        extra: ["--id", "passive-one", "--title", "Item C", "--status", "Passive"]
    }

    FileView {
        id: logA
        path: root.dir + "/a.log"
        watchChanges: true
        printErrors: false
    }

    FileView {
        id: logB
        path: root.dir + "/b.log"
        watchChanges: true
        printErrors: false
    }

    function readLog(view: var): string {
        view.reload();
        return view.text();
    }

    TrayMenuNode {
        id: probe
    }

    // Each step returns true when done; a step that does not finish within 100 ticks (10 s) fails the run.
    readonly property var steps: [
        () => {
            console.info("tray-test: host enabled=" + TrayHost.enabled);
            check("host enabled on the private bus", TrayHost.enabled);
            procA.running = true;
            procB.running = true;
            procC.running = true;
            return true;
        },
        () => {
            if (TrayHost.items.length < 2)
                return false;
            root.sniA = byTitle("Item A");
            root.sniB = byTitle("Item B");
            check("two items with the same id get two distinct slots", root.sniA !== null && root.sniB !== null && root.sniA !== root.sniB && root.sniA.id === root.sniB.id);
            check("a Passive item has no slot", byTitle("Item C") === null && TrayHost.items.length === 2);
            check("title and icon", root.sniA.title === "Item A" && root.sniA.icon !== "");
            check("A: has a menu, is not ItemIsMenu", root.sniA.hasMenu && !root.sniA.onlyMenu);
            check("B: has a menu, ItemIsMenu", root.sniB.hasMenu && root.sniB.onlyMenu);
            root.sniA.activate();
            root.sniA.secondaryActivate();
            root.sniA.scroll(120, false);
            root.sniA.scroll(-120, true);
            return true;
        },
        () => {
            const t = readLog(logA);
            if (t.indexOf("scroll -120 horizontal") < 0)
                return false;
            check("Activate, SecondaryActivate and Scroll reach the application", t.indexOf("activate ") >= 0 && t.indexOf("secondaryactivate ") >= 0 && t.indexOf("scroll 120 vertical") >= 0);
            probe.handle = root.sniB.menu;
            return true;
        },
        () => {
            if (probe.rows.length < 5)
                return false;
            const r = probe.rows;
            check("menu rows: label, separator, checked toggle, submenu, disabled",
                r[0].text === "Open" && r[1].separator === true && r[2].text === "Mute" && r[2].checked === true
                && r[3].text === "More" && r[3].submenu !== undefined && r[4].text === "Disabled" && r[4].enabled === false);
            return true;
        },
        () => {
            const sub = probe.rows[3].submenu;
            if (!sub || sub.length < 1)
                return false;
            check("submenu rows", sub[0].text === "Sub A");
            probe.rows[0].entry.triggered();
            return true;
        },
        () => {
            const t = readLog(logB);
            if (t.indexOf("event 1 clicked") < 0)
                return false;
            check("choosing a row sends the DBusMenu click to the application", true);
            // Status change: the Passive item becomes Active and gets a slot.
            Quickshell.execDetached(["sh", "-c", "printf Active > '" + root.dir + "/c.status'"]);
            return true;
        },
        () => {
            if (TrayHost.items.length < 3)
                return false;
            check("a Passive item that turns Active gets a slot", byTitle("Item C") !== null);
            Quickshell.execDetached(["sh", "-c", "printf Passive > '" + root.dir + "/a.status'"]);
            return true;
        },
        () => {
            if (byTitle("Item A") !== null)
                return false;
            check("an item that turns Passive loses its slot", TrayHost.items.length === 2);
            procB.signal(9);
            return true;
        },
        () => {
            if (byTitle("Item B") !== null)
                return false;
            check("a dead item leaves no phantom slot", !TrayHost.alive(root.sniB) && TrayHost.items.length === 1);
            return true;
        }
    ]

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            if (root.stepIndex >= root.steps.length) {
                running = false;
                console.info(root.failures.length === 0 ? "tray-test: PASS" : "tray-test: FAIL " + root.failures.join("; "));
                Qt.quit();
                return;
            }
            if (root.steps[root.stepIndex]()) {
                root.stepIndex++;
                root.waited = 0;
            } else if (++root.waited > 100) {
                root.check("step " + root.stepIndex + " finished in time", false);
                root.stepIndex = root.steps.length;
            }
        }
    }
}
