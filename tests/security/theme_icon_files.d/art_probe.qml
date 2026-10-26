pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Probe of tests/security/theme_icon_files.sh, part 6 (media art over https, offline: a local HTTPS server reached as
// https://art.test:<port> = PROBE_BASE through the test stand-in of the helper, image-copy-testnet.py, trusted through
// CURL_CA_BUNDLE). Through the REAL ThemeIcons.artSource, as both Now Playing views use it:
//  - unlocked: an https art URL becomes a PNG the shell made and its Image loads;
//  - locked (SessionState.locked): no fetch starts for a new URL (no request, no entry), the art already made still shows;
//  - unlocked again: the held URL is fetched (the binding asks again);
//  - three URLs asked in one turn (skipping through tracks): only the newest is fetched, the older ones are forgotten;
//  - the session locks while a slow fetch runs: the run is stopped at once, the URL waits, and it is fetched after unlock;
//  - the session locks inside the very change that starts a run (ThemeIcons.activeRun, before the process is started:
//    the review of 684ed6d's race): the run never starts or is stopped as soon as Quickshell reports it started, no
//    request goes out, the URL waits; and after either stop no curl process is left;
//  - retries (review of dce68c2, minor 4; delays shortened to 1 s and 2 s here): a URL that fails twice then works is
//    shown on its third try; one that always fails is asked exactly three times, then no more (its retry entry gone);
//    one no view shows any more is forgotten at its due retry, not fetched; the retry map keeps at most maxRetries.
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
    property string goneUrl: ""
    property string curls: ""
    property bool raceArmed: false
    property bool raceCreated: false

    // The race: lock inside the activeRun change of the run that carries the same-turn URL.
    Connections {
        target: ThemeIcons

        function onActiveRunChanged(): void {
            if (!root.raceArmed || ThemeIcons.activeRun === null)
                return;
            root.raceArmed = false;
            root.raceCreated = ThemeIcons.batch.some(q => q.key === "url:" + root.base + "/slow3-same");
            SessionState.locked = true;
        }
    }

    // The curl processes of this sandbox (none must outlive a stopped run).
    Process {
        id: ps
        command: ["sh", "-c", "pgrep -c -f -- \"^curl -q .*$1/\" || true", "gf-curls", root.base]
        stdout: StdioCollector {
            onStreamFinished: root.curls = text.trim()
        }
    }

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
            id: gone
            x: 100
            width: 16
            height: 16
            asynchronous: true
            source: root.goneUrl !== "" ? ThemeIcons.artSource(root.goneUrl) : ""
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
                if (root.waited === 1000)
                    ps.running = true;
                if (root.waited < 4000)
                    return;
                console.log("probe: lock-stop curls-after-1s=" + root.curls);
                // Well past the server's 3 s: nothing came of the stopped run.
                console.log("probe: lock-stop while-locked entry=" + root.stateOf(root.slowUrl) + " source=" + root.cls(slow.source.toString()));
                SessionState.locked = false;
                root.phase = "slow-unlocked";
                root.waited = 0;
            } else if (root.phase === "slow-unlocked") {
                if ((root.stateOf(root.slowUrl) !== "ok" || slow.status !== Image.Ready) && root.waited < 20000)
                    return;
                console.log("probe: lock-stop after-unlock class=" + root.cls(slow.source.toString()) + " status=" + slow.status);
                // The race: the session locks inside the activeRun change of the run that would fetch this URL.
                root.raceArmed = true;
                ThemeIcons.request("url", root.base + "/slow3-same", false);
                console.log("probe: same-turn run-created=" + root.raceCreated + " locked=" + SessionState.locked + " running-after-lock=" + (ThemeIcons.activeRun !== null));
                root.phase = "same-locked";
                root.waited = 0;
            } else if (root.phase === "same-locked") {
                if (root.waited === 1000)
                    ps.running = true;
                if (root.waited < 4000)
                    return;
                console.log("probe: same-turn while-locked entry=" + root.stateOf(root.base + "/slow3-same") + " curls-after-1s=" + root.curls);
                SessionState.locked = false;
                root.phase = "same-unlocked";
                root.waited = 0;
            } else if (root.phase === "same-unlocked") {
                if (root.stateOf(root.base + "/slow3-same") === "pending" && root.waited < 20000)
                    return;
                console.log("probe: same-turn after-unlock entry=" + root.stateOf(root.base + "/slow3-same"));
                root.flakyUrl = root.base + "/flaky";
                root.deadUrl = root.base + "/dead";
                root.goneUrl = root.base + "/dead-gone";
                root.phase = "retry";
                root.waited = 0;
            } else if (root.phase === "retry") {
                // dead-gone fails once, then no view shows it: its due retry is not fetched and it is forgotten.
                if (root.goneUrl !== "" && root.stateOf(root.goneUrl) === "no")
                    root.goneUrl = "";
                // First try, retry after 1 s, retry after 2 s more; then wait as long again to see no fourth try.
                const finished = root.stateOf(root.flakyUrl) === "ok" && root.stateOf(root.deadUrl) === "no" && ThemeIcons.retries["url:" + root.deadUrl] === undefined;
                if ((!finished || root.waited < 9000) && root.waited < 30000)
                    return;
                const gonePath = root.base + "/dead-gone";
                console.log("probe: retry flaky=" + root.stateOf(root.flakyUrl) + " class=" + root.cls(flaky.source.toString()) + " dead=" + root.stateOf(root.deadUrl)
                    + " dead-retry-entry=" + (ThemeIcons.retries["url:" + root.deadUrl] !== undefined) + " gone=" + root.stateOf(gonePath)
                    + " gone-retry-entry=" + (ThemeIcons.retries["url:" + gonePath] !== undefined));
                // The bound: with maxRetries 2, a third failure pushes the oldest entry out.
                ThemeIcons.maxRetries = 2;
                for (const k of ["url:x-one", "url:x-two", "url:x-three"])
                    ThemeIcons.scheduleRetry(k);
                console.log("probe: retry bound keys=" + Object.keys(ThemeIcons.retries).filter(k => k.startsWith("url:x-")).join(","));
                console.log("probe: done");
                Qt.exit(0);
            }
        }
    }
}
