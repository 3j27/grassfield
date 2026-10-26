pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.store

// A RUNNING store follows the file the way a fresh start reads it (GF-084 C3, security review). Quickshell's JsonAdapter does not
// replace a property whose new value loosely equals the old one (0 and false, 10 and "10", 1 and true), so a store that read the
// adapter kept the old value after an edit: lock.idleMinutes 0 ("never") edited to false stayed 0, the auto-lock stayed OFF while
// Settings and a restarted shell read 5, and "never" typed after false stayed 5. The store reads the last JSON.parse of the file text
// instead. This test rewrites the file under ONE live store, step by step, and waits for each expected reading (a store that
// keeps the old value never reaches it and the step times out). The write path is held to the same: after a deletion, an empty
// file or a malformed one the shell reads what a restart reads (lock.idleMinutes 5, never the 0 that was there), and the next
// change writes the file from the schema defaults and the file on disk, never from the adapter's retained values: the file read
// back and a fresh store started on it both agree. Offscreen (scripts/dev/test.sh: `qs -p tests/shell/settings_reload`).
// Prints "settings-reload: PASS" or the failing step.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-reload-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)

    // text of the file, then the readings expected once the store followed it: [store property, value]
    readonly property var steps: [
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":false}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":"0"}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":"0.0"}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":"-0"}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":-1}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":0.4}}', want: [["lockIdleMinutes", 5]]},
        // false, "0" then 0: "never" is not ignored until a restart
        {text: '{"version":1,"lock":{"idleMinutes":false}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":"0"}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        // 10 then "10", 1 then true: a string or a boolean is not the number it equals loosely
        {text: '{"version":1,"lock":{"idleMinutes":10}}', want: [["lockIdleMinutes", 10]]},
        {text: '{"version":1,"lock":{"idleMinutes":"10"}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":1}}', want: [["lockIdleMinutes", 1]]},
        {text: '{"version":1,"lock":{"idleMinutes":true}}', want: [["lockIdleMinutes", 5]]},
        {text: '{"version":1,"lock":{"idleMinutes":300}}', want: [["lockIdleMinutes", 240]]},
        // the same for the other keys: a boolean as a string, a number as a string, a deleted key
        {text: '{"version":1,"menubar":{"showWifi":false},"dock":{"size":64},"material":{"transparency":0.5}}',
            want: [["menubarShowWifi", false], ["dockSize", 64], ["transparency", 0.5], ["lockIdleMinutes", 5]]},
        {text: '{"version":1,"menubar":{"showWifi":"false"},"dock":{"size":"64"},"material":{"transparency":"0.5"}}',
            want: [["menubarShowWifi", true], ["dockSize", 48], ["transparency", 0.25]]},
        {text: '{"version":1,"menubar":{"showWifi":false},"dock":{"size":64},"material":{"transparency":0.5}}',
            want: [["menubarShowWifi", false], ["dockSize", 64], ["transparency", 0.5]]},
        {text: '{"version":1}', want: [["menubarShowWifi", true], ["dockSize", 48], ["transparency", 0.25]]},
        {text: '{"version":1,"pointer":{"size":60}}', want: [["pointerSize", 60]]},
        {text: '{"version":1,"pointer":{"size":"60"}}', want: [["pointerSize", 24]]},
        // The write path. A change (setDockAutohide) after a file that held 0, then false, then was deleted: the file written
        // holds lock.idleMinutes 5 (the defaults), not the 0 the adapter once held, and a restart reads the same.
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":false}}', want: [["lockIdleMinutes", 5]]},
        {op: "delete", want: [["lockIdleMinutes", 5]]},
        {op: "toggle", want: [["lockIdleMinutes", 5], ["dockAutohide", "$toggled"]],
            file: {"lock.idleMinutes": 5, "dock.autohide": "$toggled", "version": 1}, fresh: [["lockIdleMinutes", 5], ["dockAutohide", "$toggled"]]},
        // A file that held 0 and is deleted: the running shell reads 5 at once, and the next change does not write 0 back.
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {op: "delete", want: [["lockIdleMinutes", 5]]},
        {op: "toggle", want: [["lockIdleMinutes", 5], ["dockAutohide", "$toggled"]],
            file: {"lock.idleMinutes": 5, "dock.autohide": "$toggled"}, fresh: [["lockIdleMinutes", 5], ["dockAutohide", "$toggled"]]},
        // An empty file after 0: the same.
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: "", want: [["lockIdleMinutes", 5]]},
        {op: "toggle", want: [["lockIdleMinutes", 5], ["dockAutohide", "$toggled"]],
            file: {"lock.idleMinutes": 5, "dock.autohide": "$toggled"}, fresh: [["lockIdleMinutes", 5], ["dockAutohide", "$toggled"]]},
        // A malformed file after 0: the idle lock fails closed (a restart reads 5, so does the running shell), and a file
        // fixed afterwards is not overwritten with a stale value by the next change.
        {text: '{"version":1,"lock":{"idleMinutes":0}}', want: [["lockIdleMinutes", 0]]},
        {text: '{"version":1,"lock":{"idleMinutes":5,}}', want: [["lockIdleMinutes", 5], ["validRead", false], ["writeBlocked", true]]},
        {text: '{"version":1,"lock":{"idleMinutes":10}}', want: [["lockIdleMinutes", 10], ["validRead", true], ["writeBlocked", false]]},
        {op: "toggle", want: [["lockIdleMinutes", 10], ["dockAutohide", "$toggled"]],
            file: {"lock.idleMinutes": 10, "dock.autohide": "$toggled"}, fresh: [["lockIdleMinutes", 10], ["dockAutohide", "$toggled"]]},
        // A value other than a number written by hand after the shell wrote its own: the next change keeps the file's keys.
        {text: '{"version":1,"lock":{"idleMinutes":false},"dock":{"size":70}}', want: [["lockIdleMinutes", 5], ["dockSize", 70]]},
        {op: "toggle", want: [["lockIdleMinutes", 5], ["dockSize", 70], ["dockAutohide", "$toggled"]],
            file: {"lock.idleMinutes": false, "dock.size": 70, "dock.autohide": "$toggled"}, fresh: [["lockIdleMinutes", 5], ["dockSize", 70], ["dockAutohide", "$toggled"]]}
    ]

    property int step: -1
    property int tries: 0
    property bool finished: false
    // The value a toggle step set (the "$toggled" of the expectations).
    property bool toggled: false
    // The file read back for a step with `file`, and the store started on it for a step with `fresh`.
    property var fileDoc: null
    property bool freshLoaded: false
    property var fresh: null

    function finish(ok: bool, message: string): void {
        if (root.finished)
            return;
        root.finished = true;
        console.log(ok ? "settings-reload: PASS (" + root.steps.length + " live rewrites)" : "settings-reload: FAIL " + message);
        cleanup.running = true;
    }

    function expected(v: var): var {
        return v === "$toggled" ? root.toggled : v;
    }

    function readings(target: var, list: var): bool {
        for (const w of list) {
            if (target[w[0]] !== root.expected(w[1]))
                return false;
        }
        return true;
    }

    function fileMatches(spec: var): bool {
        if (root.fileDoc === null)
            return false;
        for (const path in spec) {
            let node = root.fileDoc;
            for (const part of path.split("."))
                node = node === null || node === undefined || typeof node !== "object" ? undefined : node[part];
            if (node !== root.expected(spec[path]))
                return false;
        }
        return true;
    }

    function describe(): string {
        const s = root.steps[root.step];
        const label = s.op !== undefined ? s.op : "file " + s.text;
        let out = "[blocked=" + store.writeBlocked + " valid=" + store.validRead + " dirty=" + JSON.stringify(store.dirty) + " inflight=" + JSON.stringify(store.inFlight) + " fails=" + store.writeFailures + "] step " + root.step + " (" + label + "): " + s.want.map(w => w[0] + "=" + JSON.stringify(store[w[0]]) + " wanted " + JSON.stringify(root.expected(w[1]))).join(", ");
        if (s.file !== undefined)
            out += "; file read back " + JSON.stringify(root.fileDoc) + " wanted " + JSON.stringify(s.file);
        if (s.fresh !== undefined && root.fresh !== null)
            out += "; a fresh store reads " + s.fresh.map(w => w[0] + "=" + JSON.stringify(root.fresh[w[0]])).join(", ") + " wanted " + JSON.stringify(s.fresh);
        return out;
    }

    function startFresh(): void {
        if (root.fresh !== null)
            root.fresh.destroy();
        root.freshLoaded = false;
        root.fresh = freshComponent.createObject(root, {configDir: root.base});
        root.fresh.loadedFile.connect(() => {
            root.freshLoaded = true;
        });
    }

    function next(): void {
        root.step++;
        root.tries = 0;
        if (root.step >= root.steps.length) {
            root.finish(true, "");
            return;
        }
        root.fileDoc = null;
        if (root.fresh !== null) {
            root.fresh.destroy();
            root.fresh = null;
        }
        const s = root.steps[root.step];
        if (s.op === "delete") {
            write.command = ["rm", "-f", root.base + "/grassfield.json"];
            write.running = true;
        } else if (s.op === "toggle") {
            root.toggled = !store.dockAutohide;
            store.setDockAutohide(root.toggled);
        } else {
            write.command = ["sh", "-c", 'printf "%s" "$2" > "$1.tmp" && mv "$1.tmp" "$1"', "sh", root.base + "/grassfield.json", s.text];
            write.running = true;
        }
    }

    Process {
        id: prepare
        command: ["sh", "-c", 'mkdir -p "$1" && printf "%s" "$2" > "$1/grassfield.json"', "sh", root.base, '{"version":1}']
        running: true
        onRunningChanged: {
            if (!running)
                store.configDir = root.base;
        }
    }

    SettingsStore {
        id: store
        saveDelay: 10
        onLoadedFile: {
            // The first load is the prepared file; the steps follow.
            if (root.step < 0)
                root.next();
        }
    }

    Process {
        id: write
    }

    // The file as it is on disk, for the steps that check what the shell wrote.
    Process {
        id: readback
        command: ["sh", "-c", 'cat "$1" 2>/dev/null; true', "sh", root.base + "/grassfield.json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.fileDoc = JSON.parse(text);
                } catch (e) {
                    root.fileDoc = null;
                }
            }
        }
    }

    // A store started on the same directory: what a restart reads.
    Component {
        id: freshComponent

        SettingsStore {
            saveDelay: 600000
        }
    }

    // Each step: poll until the store reads what a fresh start would, or give up after 4 s.
    Timer {
        interval: 100
        running: root.step >= 0 && !root.finished
        repeat: true
        onTriggered: {
            if (write.running || readback.running)
                return;
            const s = root.steps[root.step];
            let ok = root.readings(store, s.want);
            if (ok && s.file !== undefined) {
                readback.running = true;
                // The answer comes with the next tick; this one checks the previous.
                ok = root.fileMatches(s.file);
            }
            if (ok && s.fresh !== undefined) {
                if (root.fresh === null)
                    root.startFresh();
                ok = root.freshLoaded && root.readings(root.fresh, s.fresh);
            }
            if (ok) {
                root.next();
                return;
            }
            if (++root.tries > 60)
                root.finish(false, root.describe());
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.base]
        onRunningChanged: {
            if (!running)
                Qt.exit(root.finished && root.step >= root.steps.length ? 0 : 1);
        }
    }

    Timer {
        interval: 120000
        running: true
        onTriggered: root.finish(false, "timeout at step " + root.step)
    }
}
