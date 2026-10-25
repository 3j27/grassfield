import QtQuick
import Quickshell
import qs.lib

// Probe of tests/shell/run_mode_env.sh: prints every member of the real Mode singleton and the value of each in the environment the
// harness set, as one line `RUNMODE {json}`. GF_PROBE_NAMES is the comma list of dev-plumbing names to ask Mode.devValue about.
ShellRoot {
    id: root

    Timer {
        interval: 20
        running: true
        onTriggered: {
            const members = [];
            for (const key in Mode)
                members.push(key);
            const devValues = {};
            for (const name of (Quickshell.env("GF_PROBE_NAMES") || "").split(",").filter(n => n !== ""))
                devValues[name] = Mode.devValue(name);
            console.log("RUNMODE " + JSON.stringify({
                members: members.sort(),
                dev: Mode.dev,
                session: Mode.session,
                fixtures: Mode.fixtures,
                ownBus: Mode.ownBus,
                updateNotices: Mode.updateNotices,
                refused: Mode.refused,
                configDir: Mode.configDir,
                stateDir: Mode.stateDir,
                shellDirIsTheShellDir: Mode.shellDir === Quickshell.shellDir && Mode.shellDir !== "",
                devValues: devValues
            }));
            Qt.exit(0);
        }
    }
}
