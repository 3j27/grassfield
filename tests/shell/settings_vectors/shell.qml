pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.store

// The shell's own readers against the shared settings vectors (tests/fixtures/settings-vectors.json, the contract of
// ui/Grassfield/Ui/SettingsContract.js): every key the shell reads directly from the JSON file today must read what the
// contract reads, so that the shell and the Settings app can never show two values for one stored value (the pointer size
// did, GF-084 C2 review). A vector the shell still reads differently is marked "shell": "C3" in the fixture (slice C3 moves
// the store onto the contract): for those the test expects the shell to still differ and fails when it no longer does, so a
// mark never goes stale and the list can only shrink (C3 removes the marks). Real SettingsStore, offscreen
// (scripts/dev/test.sh: `qs -p tests/shell/settings_vectors`). Prints "settings-vectors: PASS" or the failures.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-vectors-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)

    // The vector's key -> the SettingsStore property that reads it.
    readonly property var readers: ({
            "material.transparency": "transparency",
            "accessibility.textSize": "textSize",
            "accessibility.zoomLevel": "zoomLevel",
            "dock.size": "dockSize",
            "dock.magnification": "dockMagnification",
            "lock.idleMinutes": "lockIdleMinutes",
            "pointer.size": "pointerSize",
            "appearance": "appearance",
            "notifications.history": "notificationsHistory",
            "menubar.autoHide": "menubarAutoHide",
            "menubar.showNowPlaying": "data.menubar.showNowPlaying",
            "pointer.outlineColor": "pointerOutlineColor",
            "dock.folders": "dockFolders"
        })

    property var vectors: []
    property var defaults: ({})
    property var failures: []
    property int loaded: 0
    property int knownDifferences: 0

    FileView {
        id: fixture
        path: Quickshell.shellPath("../../fixtures/settings-vectors.json")
        blockLoading: true
    }

    FileView {
        id: defaultsFile
        path: Quickshell.shellPath("../../../config/defaults/grassfield.json")
        blockLoading: true
    }

    function dataFor(v): string {
        if (v.absent === true)
            return '{"version":1}';
        const parts = v.path.split(".");
        const doc = {version: 1};
        let node = doc;
        for (let i = 0; i < parts.length - 1; i++) {
            node[parts[i]] = {};
            node = node[parts[i]];
        }
        node[parts[parts.length - 1]] = v.stored;
        return JSON.stringify(doc);
    }

    function defaultOf(path: string): var {
        let node = defaults;
        for (const part of path.split("."))
            node = node[part];
        return node;
    }

    function dir(i: int): string {
        return base + "/c" + i;
    }

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Component.onCompleted: {
        const all = JSON.parse(fixture.text()).vectors;
        defaults = JSON.parse(defaultsFile.text());
        const picked = [];
        for (const v of all) {
            if (root.readers[v.path] === undefined)
                continue;
            picked.push(v);
        }
        vectors = picked;
        setup.running = true;
    }

    Process {
        id: setup
        command: {
            const args = ['for t in "$@"; do mkdir -p "$B/c$i" && printf "%s" "$t" > "$B/c$i/grassfield.json"; i=$((i+1)); done'];
            return ["env", "B=" + root.base, "i=0", "sh", "-c", args[0], "sh"].concat(root.vectors.map(v => root.dataFor(v)));
        }
        onRunningChanged: {
            if (!running)
                repeater.model = root.vectors.length;
        }
    }

    Instantiator {
        id: repeater
        model: 0

        delegate: QtObject {
            id: item
            required property int index
            property var store: SettingsStore {
                saveDelay: 10
                configDir: root.dir(item.index)
                onLoadedFile: {
                    const v = root.vectors[item.index];
                    const want = v.default === true ? root.defaultOf(v.path) : v.read;
                    let got = this;
                    for (const part of root.readers[v.path].split("."))
                        got = got[part];
                    const same = JSON.stringify(got) === JSON.stringify(want);
                    if (v.shell === "C3") {
                        // A known difference of slice C3: it must still be one.
                        root.knownDifferences++;
                        root.check(v.name + " (" + v.path + "): marked C3 but the shell now reads the contract's " + JSON.stringify(want) + "; remove the mark", !same);
                    } else {
                        root.check(v.name + " (" + v.path + "): shell " + JSON.stringify(got) + ", contract " + JSON.stringify(want), same);
                    }
                    root.loaded++;
                    if (root.loaded === root.vectors.length)
                        cleanup.running = true;
                }
            }
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.base]
        onRunningChanged: {
            if (running)
                return;
            if (root.failures.length === 0) {
                console.log("settings-vectors: PASS (" + root.loaded + " read by the shell, " + root.knownDifferences + " of them known C3 differences, still different)");
                Qt.exit(0);
            } else {
                console.log("settings-vectors: FAIL " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }

    Timer {
        interval: 20000
        running: true
        onTriggered: {
            console.log("settings-vectors: FAIL timeout, loaded " + root.loaded + " of " + root.vectors.length);
            Qt.exit(1);
        }
    }
}
