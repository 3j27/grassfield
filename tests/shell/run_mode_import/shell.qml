import QtQuick
import Quickshell
import qs.lib
import "lib/RunMode.js" as RunMode

// ADR-0019: Quickshell resolves `import qs.lib` (the `lib` symlink next to this file, like the other shell modules) and the
// Mode singleton reads the environment through the one rule. The `dev-session` marker makes scripts/dev/test.sh run this as a dev
// session (GRASSFIELD_DEV=1, GRASSFIELD_SESSION unset, state and config under the scratch dir). Prints "run-mode-import: PASS"
// or the failures.
ShellRoot {
    id: root

    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Timer {
        interval: 50
        running: true
        onTriggered: {
            root.check("dev", Mode.dev === true);
            root.check("not a packaged session", Mode.session === false);
            root.check("fixtures need their own variable", Mode.fixtures === (Quickshell.env("GRASSFIELD_VISUAL_FIXTURES") === "1"));
            // Each property against the rule fed with the raw environment. Most variables are unset here, so a misspelled name in
            // Mode.qml would still pass: the names are checked statically by tests/unit/tst_runmode.qml (modeReads table).
            const e = n => Quickshell.env(n);
            root.check("Mode.dev is the rule", Mode.dev === RunMode.dev(e("GRASSFIELD_DEV"), e("GRASSFIELD_SESSION")));
            root.check("Mode.session is the rule", Mode.session === RunMode.session(e("GRASSFIELD_SESSION")));
            root.check("Mode.fixtures is the rule", Mode.fixtures === RunMode.fixtures(e("GRASSFIELD_DEV"), e("GRASSFIELD_SESSION"), e("GRASSFIELD_VISUAL_FIXTURES")));
            root.check("Mode.ownBus is the rule", Mode.ownBus === RunMode.ownBus(e("GRASSFIELD_DEV"), e("GRASSFIELD_SESSION"), e("GRASSFIELD_PRIVATE_BUS")));
            root.check("Mode.updateNotices is the rule", Mode.updateNotices === RunMode.updateNotices(e("GRASSFIELD_SESSION")));
            root.check("dev session without a private bus does not own the bus", e("GRASSFIELD_PRIVATE_BUS") === "1" || Mode.ownBus === false);
            root.check("a dev session has no update notices", Mode.updateNotices === false);
            root.check("stateDir is GRASSFIELD_STATE_HOME", Mode.stateDir === Quickshell.env("GRASSFIELD_STATE_HOME"));
            root.check("configDir is GRASSFIELD_CONFIG_HOME", Mode.configDir === Quickshell.env("GRASSFIELD_CONFIG_HOME"));
            root.check("shellDir", Mode.shellDir === Quickshell.shellDir && Mode.shellDir !== "");
            root.check("devValue in dev", Mode.devValue("DEV") === "1");
            root.check("devValue unset is empty", Mode.devValue("NO_SUCH_VARIABLE_FOR_THE_TEST") === "");
            if (root.failures.length === 0) {
                console.log("run-mode-import: PASS");
                Qt.exit(0);
            } else {
                console.log("run-mode-import: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }
}
