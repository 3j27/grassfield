pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform

// Gate P5 marker (shell/platform/Usable.qml): "grassfield-shell: usable" is logged once, only when the menu bar of every
// output has drawn and a Dock has drawn on every output that shows one. Run by scripts/dev/test.sh (offscreen, one
// screen). Prints "usable: PASS" and exits 0, or the failures and exits 1.
ShellRoot {
    id: root

    function run(): void {
        const fails = [];
        const screens = Quickshell.screens;
        if (screens.length < 1) {
            console.log("usable: SKIP (no screen offscreen)");
            Qt.exit(0);
            return;
        }
        const name = screens[0].name;
        // A Dock frame alone is not enough.
        Usable.report("dock", name, true);
        if (Usable.announced)
            fails.push("announced with a Dock frame and no bar frame");
        // Frames of another output's windows do not count for this one.
        Usable.report("bar", name + "-other", true);
        if (Usable.announced)
            fails.push("announced for the frame of an output that does not exist");
        Usable.report("bar", name, true);
        if (!Usable.announced)
            fails.push("not announced with the bar and the Dock drawn on the only output");
        console.log(fails.length === 0 ? "usable: PASS" : "usable: FAIL " + fails.join("; "));
        Qt.exit(fails.length === 0 ? 0 : 1);
    }

    Timer {
        interval: 200
        running: true
        onTriggered: root.run()
    }
}
