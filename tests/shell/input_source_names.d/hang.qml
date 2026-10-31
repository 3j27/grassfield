pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.I18n
import qs.platform

// Body of the second run of tests/shell/input_source_names.sh (review NIT 7): the helper's catalog is a FIFO nobody writes, so it
// blocks. After the helper's timeout (shortened here) it is stopped and the HUD shows the English name; the next change then
// gets its own helper (which blocks too and times out the same way).
ShellRoot {
    id: root

    property var shown: []
    property int phase: 0
    property real started: 0

    Connections {
        target: InputSource

        function onLayoutChanged(name: string): void {
            root.shown.push(name);
        }
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            if (root.phase === 0) {
                InputSource.helperTimeoutMs = 400;
                Translator.language = "fr";
                InputSource.feed("kbd0,English (US)");
                InputSource.feed("kbd0,German");
                root.started = Date.now();
                root.phase = 1;
            } else if (root.phase === 1 && root.shown.length > 0) {
                const ms = Date.now() - root.started;
                const ok = root.shown.length === 1 && root.shown[0] === "German" && ms < 4000;
                console.log(ok ? "PASS: input_source_hang (English name after " + ms + " ms)" : "FAIL: input_source_hang shown=" + JSON.stringify(root.shown) + " after " + ms + " ms");
                Qt.exit(ok ? 0 : 1);
            } else if (Date.now() - root.started > 15000) {
                console.log("FAIL: input_source_hang: nothing shown within 15 s");
                Qt.exit(1);
            }
        }
    }
}
