pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform

// Review of 4b8592d (minor), on the REAL MenuBridge singleton (scripts/dev/test.sh: `qs -p tests/shell/menubridge_heartbeat`,
// offscreen, no bridge running): "inhibited" from the bridge's screensaver line only lasts while the line keeps coming. The
// bridge repeats it every 20 s; a bridge that hangs without exiting stops, and after screensaverStaleMs the shell drops
// "inhibited" (fail closed: idle locking on). The stale delay is shortened to 1 s here; every "still inhibited" check is
// made only while less than that has passed since the last line (measured), so a loaded machine cannot fail it.
// Prints "menubridge-heartbeat: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int step: 0
    property real lastLine: 0
    property real start: 0
    readonly property int staleMs: 1000
    readonly property string inhibited: "{\"type\":\"screensaver\",\"inhibited\":true,\"count\":1}"

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function send(line: string): void {
        MenuBridge.handleLine(line);
        lastLine = Date.now();
    }

    // Checks "still inhibited" only when the measured time since the last line is below the stale delay.
    function stillInhibited(name: string): void {
        const elapsed = Date.now() - lastLine;
        if (elapsed < staleMs)
            check(name + " (" + elapsed + " ms after the last line)", MenuBridge.screenSaverInhibited);
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("menubridge-heartbeat: PASS");
            Qt.exit(0);
        } else {
            console.log("menubridge-heartbeat: FAIL: " + failures.join("; "));
            Qt.exit(1);
        }
    }

    Timer {
        interval: 300
        repeat: true
        running: true
        onTriggered: {
            root.step++;
            if (root.step === 1) {
                root.check("the stale delay defaults to three 20 s beats", MenuBridge.screensaverStaleMs === 60000);
                MenuBridge.screensaverStaleMs = root.staleMs;
                root.check("not inhibited without a bridge", !MenuBridge.screenSaverInhibited);
                root.send(root.inhibited);
                root.check("a screensaver line inhibits", MenuBridge.screenSaverInhibited);
            } else if (root.step <= 6) {
                // Heartbeats every 300 ms for 1.5 s: longer than the stale delay in total, so only the beats keep it.
                root.stillInhibited("a heartbeat keeps it");
                root.send(root.inhibited);
            } else if (root.step === 7) {
                root.stillInhibited("still inhibited after the last beat");
                root.start = Date.now();
            } else if (MenuBridge.screenSaverInhibited) {
                // Waiting for the stale drop (bounded).
                if (Date.now() - root.start > 15000) {
                    root.check("a silent bridge's inhibited is dropped", false);
                    stop();
                    root.finish();
                }
            } else {
                root.check("dropped no sooner than the stale delay", Date.now() - root.lastLine >= root.staleMs);
                root.send("{\"type\":\"screensaver\",\"inhibited\":false,\"count\":0}");
                root.check("an explicit false stays false", !MenuBridge.screenSaverInhibited);
                root.send("{\"type\":\"screensaver\",\"inhibited\":\"true\",\"count\":1}");
                root.check("a malformed line changes nothing", !MenuBridge.screenSaverInhibited);
                stop();
                root.finish();
            }
        }
    }
}
