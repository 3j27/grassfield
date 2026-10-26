pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.store

// A shell change back to a value the shell wrote earlier is saved even when another writer (the Settings app) changed
// grassfield.json in between. Quickshell's FileView skips a write equal to the text it last wrote; nested on
// 2026-10-24 Quick Settings Dark after Settings › Appearance Auto was applied but never saved (SettingsStore re-reads
// before writing). Run by scripts/dev/test.sh: `qs -p tests/shell/settings_external_write` (offscreen). Prints
// "settings-external-write: PASS" and exits 0, or the failures and exits 1.
ShellRoot {
    id: root

    readonly property string dir: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-settings-ext-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    readonly property string path: dir + "/grassfield.json"
    property int phase: 0
    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function appearanceOnDisk(text: string): string {
        try {
            return JSON.parse(text).appearance;
        } catch (e) {
            return "<unreadable>";
        }
    }

    // The file exists before the store starts, as in a real session: the shell's writes are then merges (the path that
    // caches the text it wrote).
    property bool seeded: false

    Process {
        running: true
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1"', "sh", root.path, '{"version":1,"appearance":"light"}']
        onRunningChanged: {
            if (!running)
                root.seeded = true;
        }
    }

    SettingsStore {
        id: store
        configDir: root.seeded ? root.dir : ""
        saveDelay: 10
        onLoadedFile: {
            // A load of the shell's own Dark write may come first: wait for the external Auto.
            if (root.phase === 2 && store.appearance === "auto") {
                // 3. the external Auto is loaded; the shell goes back to Dark (the text it wrote in step 1)
                root.phase = 3;
                store.setAppearance("dark");
                store.flush();
            }
        }
        onSaved: {
            if (root.phase === 1) {
                // 2. another writer saves Auto, the way the Settings app does (atomic replace)
                root.phase = 2;
                external.running = true;
            } else if (root.phase === 3) {
                root.phase = 4;
                readBack.running = true;
            }
        }
    }

    Process {
        id: external
        command: ["sh", "-c", 'printf "%s\\n" "$2" > "$1.tmp" && mv "$1.tmp" "$1"', "sh", root.path, '{"version":1,"appearance":"auto"}']
    }

    Process {
        id: readBack
        command: ["cat", root.path]
        stdout: StdioCollector {
            onStreamFinished: {
                root.check("dark saved after the external write (file says " + root.appearanceOnDisk(text) + ")", root.appearanceOnDisk(text) === "dark");
                cleanup.running = true;
            }
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.dir]
        onRunningChanged: {
            if (running)
                return;
            if (root.failures.length === 0) {
                console.log("settings-external-write: PASS");
                Qt.exit(0);
            } else {
                console.log("settings-external-write: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }

    // 1. once the seeded file is loaded, the shell writes Dark (a merge)
    Timer {
        interval: 300
        running: root.seeded
        onTriggered: {
            root.phase = 1;
            store.setAppearance("dark");
            store.flush();
        }
    }

    Timer {
        interval: 20000
        running: true
        onTriggered: {
            root.check("finished in time (stuck in phase " + root.phase + ")", false);
            cleanup.running = true;
        }
    }
}
