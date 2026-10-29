pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform
import qs.services
import "platform/WindowTiling.js" as WindowTiling

// Tiling step 6a (docs/specs/tiling.md TL33, ADR-0036 D43, D51; integrator review of c7a6b6e, MAJORs 2 and 3, MINOR 9): a
// Split View Desktop never keeps an empty half, and nothing of it acts behind the lock, on the REAL singletons
// (scripts/dev/test.sh: offscreen, a dev session whose config is under the scratch dir; no compositor: the plugin's features
// and its reply's Split View Desktops are set by hand, and nothing reaches a compositor). Checks:
//  - one member waiting for its second window while its picker is on its way (a suggestion asked, its reply awaited): it is
//    not filled;
//  - the reply came without a picker shown (refused over another surface, timed out, dismissed): it is filled (sent once);
//  - two members, or one that no longer waits: nothing is filled;
//  - locked: nothing is filled, and fillAlone, tile, split and unsplit refuse; unlocked: the lonely member is sent again.
// Prints "split-view: PASS (n checks)" or the failures. It refuses to run outside scripts/dev/test.sh's scratch session
// (a compositor reachable through HYPRLAND_INSTANCE_SIGNATURE would receive the fills).
ShellRoot {
    id: root

    readonly property var features: ["config", "window-tiling", "tiling-arrange", "tiling-layouts", "tiling-split"]
    property var failures: []
    property int checks: 0
    property int step: -1
    property real started: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    function split(windows: var, waiting: bool): var {
        return {workspace: 4, output: "GF-REF", home: 1, windows: windows, waiting: waiting};
    }

    function refusal(): string {
        const tmp = Quickshell.env("GRASSFIELD_TEST_TMP");
        const home = Quickshell.env("GRASSFIELD_CONFIG_HOME");
        if (!tmp || !home)
            return "GRASSFIELD_TEST_TMP and GRASSFIELD_CONFIG_HOME are not both set (scripts/dev/test.sh sets them)";
        if (String(home).indexOf(String(tmp) + "/") !== 0)
            return "GRASSFIELD_CONFIG_HOME (" + home + ") is not under GRASSFIELD_TEST_TMP (" + tmp + ")";
        if (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"))
            return "HYPRLAND_INSTANCE_SIGNATURE is set: the fills would reach a live compositor";
        return "";
    }

    function steps(): var {
        return [{
                // The features make TilingLink fetch the reply (no hyprctl here: it ends empty or at its deadline, setting no
                // Split View Desktop); the steps set theirs after it.
                name: "features",
                act: () => {
                    Capabilities.features = root.features;
                    Capabilities.pluginPresent = true;
                    SessionState.locked = false;
                },
                until: () => Date.now() - root.started > WindowTiling.suggestionWaitMs + 500
            }, {
                name: "picker on its way",
                act: () => {
                    Compositor.suggestionAsked = {address: "a1", until: Date.now() + 60000};
                    TilingLink.awaiting = true;
                    TilingLink.splits = [root.split(["a1"], true)];
                },
                until: () => true,
                check: () => {
                    root.check("picker on its way: the member is not filled (" + JSON.stringify(TilingSuggest.lonely) + ")", TilingSuggest.lonely.length === 0);
                    root.check("picker on its way: nothing sent", TilingSuggest.filled["a1"] !== true);
                }
            }, {
                name: "no picker",
                act: () => {
                    TilingLink.awaiting = false; // the reply came, no picker could show (TilingSuggest.show refused it)
                },
                until: () => true,
                check: () => {
                    root.check("no picker: the member fills its Desktop (" + JSON.stringify(TilingSuggest.lonely) + ")", JSON.stringify(TilingSuggest.lonely) === JSON.stringify(["a1"]));
                    root.check("no picker: its fill was sent", TilingSuggest.filled["a1"] === true);
                }
            }, {
                name: "two members",
                act: () => {
                    TilingLink.splits = [root.split(["a1", "b2"], false)];
                },
                until: () => true,
                check: () => {
                    root.check("two members: nothing to fill", TilingSuggest.lonely.length === 0);
                    root.check("two members: nothing remembered as sent", TilingSuggest.filled["a1"] !== true);
                }
            }, {
                name: "not waiting",
                act: () => {
                    TilingLink.splits = [root.split(["a1"], false)];
                },
                until: () => true,
                check: () => root.check("one member, not waiting: the plugin fills it itself", TilingSuggest.lonely.length === 0)
            }, {
                name: "locked",
                act: () => {
                    SessionState.locked = true; // first: nothing may be sent while the lonely member appears
                    TilingLink.splits = [root.split(["a1"], true)];
                },
                until: () => true,
                check: () => {
                    root.check("locked: nothing is filled", TilingSuggest.lonely.length === 0);
                    root.check("locked: nothing remembered as sent", TilingSuggest.filled["a1"] !== true);
                    root.check("locked: fillAlone refuses", Compositor.fillAlone("a1") === false);
                    root.check("locked: tile refuses", Compositor.tile(null, "fill") === false);
                    root.check("locked: split refuses", Compositor.split(null, "left") === false);
                    root.check("locked: unsplit refuses", Compositor.unsplit(null) === false);
                }
            }, {
                name: "unlocked",
                act: () => {
                    SessionState.locked = false;
                },
                until: () => true,
                check: () => {
                    root.check("unlocked: the lonely member fills (" + JSON.stringify(TilingSuggest.lonely) + ")", JSON.stringify(TilingSuggest.lonely) === JSON.stringify(["a1"]));
                    root.check("unlocked: its fill is sent again", TilingSuggest.filled["a1"] === true);
                }
            }, {
                name: "end",
                act: () => {
                    TilingLink.splits = [];
                    Compositor.suggestionAsked = null;
                },
                until: () => true,
                check: () => root.check("end: no Split View Desktop, nothing to fill", TilingSuggest.lonely.length === 0)
            }];
    }

    function begin(i: int): void {
        root.step = i;
        root.started = Date.now();
        root.steps()[i].act();
    }

    function finish(): void {
        ticker.stop();
        if (root.failures.length === 0) {
            console.log("split-view: PASS (" + root.checks + " checks)");
            Qt.exit(0);
        } else {
            console.log("split-view: FAIL: " + root.failures.join("; "));
            Qt.exit(1);
        }
    }

    // Each step acts, then its checks run at the next tick (the bindings have settled). A step that times out is a failure.
    function tick(): void {
        if (root.step < 0) {
            const why = root.refusal();
            if (why !== "") {
                ticker.stop();
                console.log("split-view: FAIL: refused to run: " + why);
                Qt.exit(1);
                return;
            }
            root.begin(0);
            return;
        }
        const s = root.steps()[root.step];
        if (!s.until()) {
            if (Date.now() - root.started < WindowTiling.suggestionWaitMs + 8000)
                return;
            root.check(s.name + ": timed out", false);
        } else if (s.check) {
            s.check();
        }
        if (root.step + 1 < root.steps().length)
            root.begin(root.step + 1);
        else
            root.finish();
    }

    Timer {
        id: ticker
        interval: 100
        repeat: true
        running: true
        onTriggered: root.tick()
    }
}
