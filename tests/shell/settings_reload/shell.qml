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
// keeps the old value never reaches it and the step times out). Offscreen (scripts/dev/test.sh: `qs -p tests/shell/settings_reload`).
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
        {text: '{"version":1,"pointer":{"size":"60"}}', want: [["pointerSize", 24]]}
    ]

    property int step: -1
    property int tries: 0
    property bool finished: false

    function finish(ok: bool, message: string): void {
        if (root.finished)
            return;
        root.finished = true;
        console.log(ok ? "settings-reload: PASS (" + root.steps.length + " live rewrites)" : "settings-reload: FAIL " + message);
        cleanup.running = true;
    }

    function matches(): bool {
        for (const w of root.steps[root.step].want) {
            if (store[w[0]] !== w[1])
                return false;
        }
        return true;
    }

    function describe(): string {
        const s = root.steps[root.step];
        return "step " + root.step + " (file " + s.text + "): " + s.want.map(w => w[0] + "=" + JSON.stringify(store[w[0]]) + " wanted " + JSON.stringify(w[1])).join(", ");
    }

    function next(): void {
        root.step++;
        root.tries = 0;
        if (root.step >= root.steps.length) {
            root.finish(true, "");
            return;
        }
        write.command = ["sh", "-c", 'printf "%s" "$2" > "$1.tmp" && mv "$1.tmp" "$1"', "sh", root.base + "/grassfield.json", root.steps[root.step].text];
        write.running = true;
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

    // Each step: poll until the store reads what a fresh start would, or give up after 4 s.
    Timer {
        interval: 100
        running: root.step >= 0 && !root.finished
        repeat: true
        onTriggered: {
            if (write.running)
                return;
            if (root.matches()) {
                root.next();
                return;
            }
            if (++root.tries > 40)
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
