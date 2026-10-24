pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.services

// Probe of tests/security/theme_icon_files.sh, part 6 (media art over https, offline: a local HTTPS server reached as
// https://art.test:<port> = PROBE_BASE through the test stand-in of the helper, image-copy-testnet.py, trusted through
// CURL_CA_BUNDLE). Through the REAL ThemeIcons.artSource, as both Now Playing views use it:
//  - unlocked: an https art URL becomes a PNG the shell made and its Image loads;
//  - locked (SessionState.locked): no fetch starts for a new URL (no request, no entry), the art already made still shows;
//  - unlocked again: the held URL is fetched (the binding asks again);
//  - three URLs asked in one turn (skipping through tracks): only the newest is fetched, the older ones are forgotten;
//  - the session locks while a slow fetch runs: the run is stopped at once, the URL waits, and it is fetched after unlock;
//  - retries (review of dce68c2, minor 4; delays shortened to 1 s and 2 s here): a URL that fails twice then works is
//    shown on its third try; one that always fails is asked exactly three times, then no more.
// Prints "probe:" lines and "probe: done", then exits.
ShellRoot {
    id: root

    readonly property string base: Quickshell.env("PROBE_BASE")
    property string phase: "unlocked"
    property int waited: 0
    property string lockedUrl: ""
    property string slowUrl: ""
    property string flakyUrl: ""
    property string deadUrl: ""

    function stateOf(url: string): string {
        const e = ThemeIcons.copies["url:" + url];
        return e === undefined ? "none" : e.state;
    }

    function cls(source: string): string {
        return source === "" ? "none" : (source.startsWith("file://") && source.indexOf("/grassfield-icons-") > 0 && source.endsWith(".png") ? "copy" : "other:" + source);
    }

    function idle(): bool {
        return ThemeIcons.queue.length === 0 && ThemeIcons.batch.length === 0 && ThemeIcons.activeRun === null;
    }

    function fetching(url: string): bool {
        return ThemeIcons.activeRun !== null && ThemeIcons.batch.some(q => q.key === "url:" + url);
    }

    Component.onCompleted: {
        ThemeIcons.retryDelaysMs = [1000, 2000];
        ThemeIcons.retryTickMs = 250;
    }

    FloatingWindow {
        visible: true
        implicitWidth: 120
        implicitHeight: 40

        Image {
            id: shown
            width: 16
            height: 16
            asynchronous: true
            source: ThemeIcons.artSource(root.base + "/ok.png")
        }

        Image {
            id: held
            x: 20
            width: 16
            height: 16
            asynchronous: true
            source: root.lockedUrl !== "" ? ThemeIcons.artSource(root.lockedUrl) : ""
        }

        Image {
            id: slow
            x: 40
            width: 16
            height: 16
            asynchronous: true
            source: root.slowUrl !== "" ? ThemeIcons.artSource(root.slowUrl) : ""
        }

        Image {
            id: flaky
            x: 60
            width: 16
            height: 16
            asynchronous: true
            source: root.flakyUrl !== "" ? ThemeIcons.artSource(root.flakyUrl) : ""
        }

        Image {
            id: dead
            x: 80
            width: 16
            height: 16
            asynchronous: true
            source: root.deadUrl !== "" ? ThemeIcons.artSource(root.deadUrl) : ""
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "unlocked") {
                if ((root.stateOf(root.base + "/ok.png") !== "ok" || shown.status !== Image.Ready) && root.waited < 20000)
                    return;
                console.log("probe: unlocked class=" + root.cls(shown.source.toString()) + " status=" + shown.status);
                SessionState.locked = true;
                root.lockedUrl = root.base + "/locked.png";
                root.phase = "locked";
                root.waited = 0;
            } else if (root.phase === "locked") {
                if (root.waited < 2000)
                    return;
                console.log("probe: locked source=" + root.cls(held.source.toString()) + " entry=" + root.stateOf(root.lockedUrl) + " cached=" + root.cls(ThemeIcons.artSource(root.base + "/ok.png")));
                SessionState.locked = false;
                root.phase = "unlock";
                root.waited = 0;
            } else if (root.phase === "unlock") {
                if ((root.stateOf(root.lockedUrl) !== "ok" || held.status !== Image.Ready) && root.waited < 20000)
                    return;
                console.log("probe: after-unlock class=" + root.cls(held.source.toString()) + " status=" + held.status);
                // Skipping through three tracks in one turn.
                for (const name of ["a", "b", "c"])
                    ThemeIcons.artSource(root.base + "/" + name + ".png");
                root.phase = "newest";
                root.waited = 0;
            } else if (root.phase === "newest") {
                if ((!root.idle() || root.waited < 500) && root.waited < 20000)
                    return;
                console.log("probe: newest a=" + root.stateOf(root.base + "/a.png") + " b=" + root.stateOf(root.base + "/b.png") + " c=" + root.stateOf(root.base + "/c.png"));
                root.slowUrl = root.base + "/slow3";
                root.phase = "slow";
                root.waited = 0;
            } else if (root.phase === "slow") {
                // The fetch is under way (the server answers after 3 s): lock half a second into it.
                if (!root.fetching(root.slowUrl) && root.waited < 10000)
                    return;
                if (root.waited < 600)
                    return;
                SessionState.locked = true;
                console.log("probe: lock-stop running=" + (ThemeIcons.activeRun !== null) + " entry=" + root.stateOf(root.slowUrl)
                    + " queued=" + ThemeIcons.queue.some(q => q.key === "url:" + root.slowUrl));
                root.phase = "slow-locked";
                root.waited = 0;
            } else if (root.phase === "slow-locked") {
                if (root.waited < 4000)
                    return;
                // Well past the server's 3 s: nothing came of the stopped run.
                console.log("probe: lock-stop while-locked entry=" + root.stateOf(root.slowUrl) + " source=" + root.cls(slow.source.toString()));
                SessionState.locked = false;
                root.phase = "slow-unlocked";
                root.waited = 0;
            } else if (root.phase === "slow-unlocked") {
                if ((root.stateOf(root.slowUrl) !== "ok" || slow.status !== Image.Ready) && root.waited < 20000)
                    return;
                console.log("probe: lock-stop after-unlock class=" + root.cls(slow.source.toString()) + " status=" + slow.status);
                root.flakyUrl = root.base + "/flaky";
                root.deadUrl = root.base + "/dead";
                root.phase = "retry";
                root.waited = 0;
            } else if (root.phase === "retry") {
                // First try, retry after 1 s, retry after 2 s more; then wait as long again to see no fourth try.
                const r = ThemeIcons.retries["url:" + root.deadUrl];
                const finished = root.stateOf(root.flakyUrl) === "ok" && r !== undefined && r.done;
                if ((!finished || root.waited < 9000) && root.waited < 30000)
                    return;
                console.log("probe: retry flaky=" + root.stateOf(root.flakyUrl) + " class=" + root.cls(flaky.source.toString()) + " dead=" + root.stateOf(root.deadUrl)
                    + " tries=" + (r ? r.tries : -1) + " done=" + (r ? r.done : false));
                console.log("probe: done");
                Qt.exit(0);
            }
        }
    }
}
