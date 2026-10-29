pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform
import qs.services
import "platform/WindowTiling.js" as WindowTiling

// Tiling step 6a (docs/specs/tiling.md TL33, ADR-0036 D43, D51; integrator reviews of c7a6b6e and e5bd9d2): a Split View
// Desktop never keeps an empty half, and nothing of it acts behind the lock, on the REAL singletons (scripts/dev/test.sh:
// offscreen, a dev session whose config is under the scratch dir; no compositor: the plugin's features and its reply's Split
// View Desktops are set by hand, and nothing reaches a compositor). TilingLink is created and its startup fetch done before
// any Split View Desktop is set (re-review of e5bd9d2: that fetch overwrote them). Checks:
//  - one member waiting for its second window while its picker is on its way (a suggestion asked, its reply awaited): it is
//    not filled; nor while its picker is shown;
//  - the reply came without a picker shown (refused over another surface, dismissed): it is filled (sent once);
//  - the plugin refuses that fill because it still reports the lock (the unlock race): the fill is sent again;
//  - the fetch of the picker's suggestion gives up at its deadline: the member is filled, and a reply that does not read
//    keeps the Split View Desktops;
//  - two members, or one that no longer waits: nothing is filled;
//  - the shell's own lock (its popups close, then its lock state changes): no fill as it begins;
//  - locked: nothing is filled, and fillAlone, tile, split and unsplit are refused by their own gates (SessionState names
//    the refusal); unlocked: the lonely member is sent again;
//  - a popup that closes itself as it opens (the tiling popover on a member, #48 nested pass): nothing stays open or active
//    (the overlay would stay mapped over every click and key); a popup closed behind Popups' back as it opens: Popups.verify
//    computes a stale `active` again.
// Prints "split-view: PASS (n checks)" or the failures. It refuses to run outside scripts/dev/test.sh's scratch session
// (a compositor reachable through HYPRLAND_INSTANCE_SIGNATURE would receive the fills).
ShellRoot {
    id: root

    readonly property var features: ["config", "window-tiling", "tiling-arrange", "tiling-layouts", "tiling-split"]
    property var failures: []
    property int checks: 0
    property int step: -1
    property real started: 0
    // A popup that closes itself as it opens (step "a popup closing itself as it opens"): its close runs inside the update of
    // Popups.active, as the tiling popover's did inside the overlay's Loader.
    property bool selfClosing: false
    readonly property bool popupActive: Popups.active

    // A popup closed behind Popups' back as it opens (step "a stale active is computed again"): `kind` written inside the
    // update of Popups.active, which a binding loop then leaves stale.
    property bool rawClose: false

    onPopupActiveChanged: {
        if (root.popupActive && root.selfClosing)
            Popups.close();
        if (root.popupActive && root.rawClose)
            Popups.kind = "";
    }

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    function split(windows: var, waiting: bool): var {
        return {workspace: 4, output: "GF-REF", home: 1, windows: windows, waiting: waiting};
    }

    // `call` refused by the gate named `surface` (SessionState.refuses records the last surface it refused).
    function refusedBy(surface: string, call: var): bool {
        SessionState.lastRefused = "";
        const result = call();
        return result === false && SessionState.lastRefused === surface;
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
                // TilingLink created now; the features make it fetch the reply (no compositor here: it ends unread or at its
                // deadline, then one retry); the steps set their Split View Desktops after it.
                name: "features",
                act: () => {
                    TilingLink.splits = [];
                    Capabilities.features = root.features;
                    Capabilities.pluginPresent = true;
                    SessionState.locked = false;
                },
                until: () => Date.now() - root.started > WindowTiling.suggestionWaitMs * 2 + 500
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
                name: "picker shown",
                act: () => {
                    // The reply came and its picker shows (shown first: no moment without a pending picker).
                    Popups.open("tilingSuggest", "", 0, 0, "zone", {suggestion: {gen: 1, address: "a1", layout: "left-right", output: "", zones: [{zone: 1, x: 0, y: 0, w: 900, h: 900}], windows: ["b2"]}});
                    TilingLink.awaiting = false;
                },
                until: () => true,
                check: () => {
                    root.check("picker shown: it is shown", TilingSuggest.shown);
                    root.check("picker shown: the member is not filled (" + JSON.stringify(TilingSuggest.lonely) + ")", TilingSuggest.lonely.length === 0);
                }
            }, {
                name: "no picker",
                act: () => {
                    Popups.close(); // dismissed, or refused over another surface: no picker any more
                },
                until: () => true,
                check: () => {
                    root.check("no picker: the member fills its Desktop (" + JSON.stringify(TilingSuggest.lonely) + ")", JSON.stringify(TilingSuggest.lonely) === JSON.stringify(["a1"]));
                    root.check("no picker: its fill was sent", TilingSuggest.filled["a1"] === true);
                }
            }, {
                name: "refused while the plugin is locked",
                act: () => {
                    Compositor.tilingNotice({v: "gfc/1", type: "tiling", gen: 9, reason: "locked"});
                    root.check("refused: the fill is not taken as done", TilingSuggest.filled["a1"] !== true);
                },
                until: () => Date.now() - root.started > 900,
                check: () => root.check("refused: the fill is sent again", TilingSuggest.filled["a1"] === true)
            }, {
                name: "deadline",
                act: () => {
                    TilingLink.splits = [root.split(["a1", "b2"], false)]; // the fill above is forgotten
                    Compositor.suggestionAsked = {address: "c3", until: Date.now() + 60000};
                    TilingLink.awaiting = true;
                    TilingLink.splits = [root.split(["c3"], true)];
                    root.check("deadline: before it, its picker is on its way", TilingSuggest.lonely.length === 0);
                    TilingLink.giveUp();
                },
                until: () => Date.now() - root.started > WindowTiling.suggestionWaitMs / 3 + 1500,
                check: () => {
                    root.check("deadline: the member fills (" + JSON.stringify(TilingSuggest.lonely) + ")", JSON.stringify(TilingSuggest.lonely) === JSON.stringify(["c3"]));
                    root.check("deadline: its fill was sent", TilingSuggest.filled["c3"] === true);
                    root.check("deadline: the retry's unread reply kept the Split View Desktops (" + JSON.stringify(TilingLink.splits) + ")",
                        TilingLink.splits.length === 1 && TilingLink.splits[0].windows[0] === "c3");
                }
            }, {
                name: "two members",
                act: () => {
                    Compositor.suggestionAsked = null;
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
                name: "the shell's own lock",
                act: () => {
                    // A picker shown for a lonely member, then Lock.lock(): the popups close first, the lock state changes
                    // next, in the same event (#48 nested pass, MINOR B).
                    Popups.open("tilingSuggest", "", 0, 0, "zone", {suggestion: {gen: 2, address: "a1", layout: "left-right", output: "", zones: [{zone: 1, x: 0, y: 0, w: 900, h: 900}], windows: ["b2"]}});
                    TilingLink.splits = [root.split(["a1"], true)];
                    TilingSuggest.lastSent = "";
                    Popups.close();
                    SessionState.locked = true;
                },
                until: () => true,
                check: () => root.check("the shell's own lock: no fill as it begins (" + TilingSuggest.lastSent + ")", TilingSuggest.lastSent === "")
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
                    root.check("locked: fillAlone is refused by its gate", root.refusedBy("windows fill alone", () => Compositor.fillAlone("a1")));
                    root.check("locked: tile is refused by its gate", root.refusedBy("windows tile", () => Compositor.tile("a1", "fill")));
                    root.check("locked: split is refused by its gate", root.refusedBy("windows split", () => Compositor.split("a1", "left")));
                    root.check("locked: unsplit is refused by its gate", root.refusedBy("windows unsplit", () => Compositor.unsplit("a1")));
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
                    root.check("unlocked: that fill went out now (" + TilingSuggest.lastSent + ")", TilingSuggest.lastSent === "a1");
                }
            }, {
                name: "a popup closing itself as it opens",
                act: () => {
                    // The tiling popover on a member did (#48 nested pass, BLOCKER A): its close, made inside the open, left
                    // Popups.active true with no popup, and the overlay mapped over every click and key.
                    root.selfClosing = true;
                    Popups.open("tiling", "", 0, 0, "below", {address: "a1"});
                    root.selfClosing = false;
                },
                until: () => true,
                check: () => {
                    root.check("closing itself as it opens: closed (" + Popups.kind + ")", Popups.kind === "");
                    root.check("closing itself as it opens: nothing left active for the overlay", !Popups.active);
                }
            }, {
                name: "a stale active is computed again",
                act: () => {
                    root.rawClose = true;
                    Popups.open("tiling", "", 0, 0, "below", {address: "a1"});
                    root.rawClose = false;
                },
                until: () => true,
                check: () => {
                    console.log("split-view: after the raw close, active " + Popups.active + " with kind \"" + Popups.kind + "\"");
                    Popups.verify();
                    root.check("stale active: computed again by verify (" + Popups.active + ")", Popups.kind === "" && !Popups.active);
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

    // Each step acts, then its checks run once its condition holds (the bindings have settled at the next tick). A step that
    // times out is a failure.
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
            if (Date.now() - root.started < WindowTiling.suggestionWaitMs * 2 + 8000)
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
