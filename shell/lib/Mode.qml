pragma Singleton
import QtQuick
import Quickshell
import "RunMode.js" as RunMode

// The only reader of GRASSFIELD_* in the shell (ADR-0019; enforced from M8 by tests/ci/run_mode.py). Consumers ask Mode;
// the rule itself is RunMode.js. No consumer is migrated yet (slices M2 to M5).
Singleton {
    id: root

    // Test hooks allowed and never act on the owner's machine: GRASSFIELD_DEV "1" and GRASSFIELD_SESSION not "1".
    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    // A packaged session (GRASSFIELD_SESSION "1").
    readonly property bool session: RunMode.session(Quickshell.env("GRASSFIELD_SESSION"))
    // Deterministic visual fixtures (dev and GRASSFIELD_VISUAL_FIXTURES "1").
    readonly property bool fixtures: RunMode.fixtures(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_VISUAL_FIXTURES"))
    // The shell owns the session bus names and may drive real players: not dev, or dev on a private bus.
    readonly property bool ownBus: RunMode.ownBus(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_PRIVATE_BUS"))
    readonly property bool updateNotices: RunMode.updateNotices(Quickshell.env("GRASSFIELD_SESSION"))

    readonly property string configDir: RunMode.configDir(Quickshell.env("GRASSFIELD_CONFIG_HOME"), Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME"))
    readonly property string stateDir: RunMode.stateDir(Quickshell.env("GRASSFIELD_STATE_HOME"), Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME"))
    readonly property string shellDir: Quickshell.shellDir

    // A dev-plumbing variable GRASSFIELD_<name> (ADR-0019 table): its value in dev, "" otherwise.
    function devValue(name) {
        return RunMode.devPlumbing(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"), Quickshell.env("GRASSFIELD_" + name));
    }
}
