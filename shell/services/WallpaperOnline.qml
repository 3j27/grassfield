pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// The online daily wallpaper (ADR-0016 step 2, Wikimedia Commons Picture of the Day): when to fetch it, the picture on
// disk and what it reports. The shell never talks to the network itself: every fetch is one run of
// `grassfield-wallpaper fetch commons` (an argument vector; curl inside), and `latest` reads the cache. What to do and when
// is decided by the pure rules of WallpaperConfig.js (onlineSchedule, onlineAfter); this service only runs them.
//   - Off by default: nothing runs unless wallpaper.source is "online" (top level or a display's override).
//   - One successful fetch per UTC day, at a random time after 00:10 UTC (the first fetch, with nothing cached, at once);
//     backoff 1 h, 3 h, then the next day. The state is kept in $XDG_STATE_HOME/grassfield/wallpaper-online.json.
//   - Only while NetworkManager reports a fully usable network and the connection is not metered. Quickshell exposes the
//     connectivity but not the metered flag: a fetch asks `nmcli` once, just before it starts (never polled). Without a
//     NetworkManager backend there is nothing to ask and the fetch simply runs (curl fails when offline: backoff).
//   - A dev session never fetches, except from the loopback test server named by GRASSFIELD_ONLINE_BASE_URL
//     (http://127.0.0.1:<port>); the helper refuses that URL without GRASSFIELD_DEV=1.
//   - Offline: the last cached picture stays; with nothing cached the feeds draw the artwork and Settings says "Waiting
//     for a connection".
Singleton {
    id: root

    readonly property bool wanted: WallpaperConfig.onlineWanted(Settings.wallpaper)
    readonly property string provider: WallpaperConfig.normalize(Settings.wallpaper).online.provider
    readonly property string outDir: WallpaperState.cacheDir + "/online/" + provider
    // The loopback origin of a dev session's test server, "" otherwise.
    readonly property string devBaseUrl: {
        const u = WallpaperState.dev ? Quickshell.env("GRASSFIELD_ONLINE_BASE_URL") : "";
        return /^http:\/\/127\.0\.0\.1:\d{1,5}$/.test(u) ? u : "";
    }
    readonly property string lang: Qt.locale().name.substring(0, 2) === "fr" ? "fr" : "en"

    // The newest cached picture {date, file, title, author, credit, caption, licenseShort, licenseUrl, sourceUrl, fetchedAt,
    // width, height}, or null. Replaced only by the helper's own answers.
    property var entry: null
    property bool entryLoaded: false
    // idle (not wanted) | waiting (no usable connection, or a metered one) | scheduled | fetching
    property string phase: "idle"
    // Persisted scheduler state (WallpaperConfig.onlineStateOf).
    property var sched: ({})
    property bool schedLoaded: false
    // The last failure, for the journal and the Settings pane ("" when the last fetch worked).
    property string lastFailure: ""
    // Observable by tests.
    property int fetchCount: 0
    property real nextAt: 0

    readonly property bool ready: wanted && schedLoaded && entryLoaded && WallpaperState.toolChecked && !WallpaperState.toolMissing

    readonly property string stateFile: WallpaperState.stateDir + "/wallpaper-online.json"

    onWantedChanged: {
        if (wanted) {
            loadLatest();
            evaluate();
        } else {
            phase = "idle";
            nextTimer.stop();
            publish();
        }
    }
    onReadyChanged: evaluate()
    onEntryChanged: publish()
    onPhaseChanged: publish()

    // Connectivity changes re-evaluate (event driven; no polling).
    Connections {
        target: Connectivity
        function onFullyConnectedChanged(): void {
            if (Connectivity.fullyConnected)
                root.evaluate();
        }
    }

    function publish(): void {
        const e = root.entry;
        WallpaperState.reportOnline({
            phase: root.phase,
            provider: root.provider,
            failure: root.lastFailure,
            entry: e ? {date: e.date, file: e.file, title: e.title, author: e.author, credit: e.credit, caption: e.caption, licenseShort: e.licenseShort, licenseUrl: e.licenseUrl, sourceUrl: e.sourceUrl, fetchedAt: e.fetchedAt} : null
        });
    }

    // ---- the cache ----
    function loadLatest(): void {
        if (!WallpaperState.toolChecked || WallpaperState.toolMissing)
            return;
        const args = WallpaperConfig.latestArgs(WallpaperState.tool, root.provider, root.outDir);
        if (args === null) {
            root.entryLoaded = true;
            return;
        }
        latestProc.command = args;
        latestProc.running = true;
    }

    Connections {
        target: WallpaperState
        function onToolCheckedChanged(): void {
            if (root.wanted)
                root.loadLatest();
        }
    }

    Component.onCompleted: {
        if (wanted)
            loadLatest();
    }

    function adopt(o: var): void {
        // Only a complete, plausible answer replaces the picture: a path inside our own cache folder and the text fields.
        if (o && o.ok === true && o.found === true && typeof o.file === "string" && WallpaperConfig.isUnder(o.file, root.outDir) && typeof o.date === "string") {
            if (!root.entry || root.entry.file !== o.file || root.entry.fetchedAt !== o.fetchedAt)
                root.entry = o;
        }
    }

    Process {
        id: latestProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.adopt(JSON.parse(text));
                } catch (e) {
                    console.warn("wallpaper online: unreadable answer of latest");
                }
                root.entryLoaded = true;
                root.evaluate();
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (exitCode !== 0 && !root.entryLoaded) {
                root.entryLoaded = true;
                root.evaluate();
            }
        }
        // qmllint enable signal-handler-parameters
    }

    // ---- the persisted state ----
    Process {
        id: mkdir
        command: ["mkdir", "-p", "-m", "700", WallpaperState.stateDir]
        running: true
        onRunningChanged: if (!running)
            stateReader.path = root.stateFile
    }

    FileView {
        id: stateReader
        printErrors: false
        onLoaded: {
            try {
                root.sched = WallpaperConfig.onlineStateOf(JSON.parse(text()));
            } catch (e) {
                root.sched = WallpaperConfig.onlineStateOf(null);
            }
            root.schedLoaded = true;
        }
        onLoadFailed: {
            root.sched = WallpaperConfig.onlineStateOf(null);
            root.schedLoaded = true;
        }
    }

    FileView {
        id: stateWriter
        path: stateReader.path
        printErrors: false
        atomicWrites: true
    }

    function saveState(st: var): void {
        sched = st;
        stateWriter.setText(JSON.stringify(st, null, 2) + "\n");
    }

    // ---- the decision ----
    Timer {
        id: nextTimer
        onTriggered: root.evaluate()
    }

    function evaluate(): void {
        if (!ready || fetchProc.running || meteredProc.running)
            return;
        const now = Date.now();
        const r = WallpaperConfig.onlineSchedule(sched, now, entry !== null, Math.random());
        if (r.state.slotDate !== sched.slotDate || r.state.slotAt !== sched.slotAt)
            saveState(r.state);
        if (r.due) {
            tryFetch(r.date);
            return;
        }
        nextAt = r.at;
        phase = "scheduled";
        nextTimer.interval = Math.max(1000, Math.min(r.at - now, Tokens.wallpaperOnlineMaxWaitMs));
        nextTimer.restart();
    }

    // The date of the fetch under way.
    property string fetchDate: ""

    function networkOk(): bool {
        // A dev session: only the loopback test server.
        if (WallpaperState.dev)
            return devBaseUrl !== "";
        return Connectivity.fullyConnected;
    }

    function tryFetch(date: string): void {
        if (!networkOk()) {
            phase = "waiting";
            // A change of connectivity re-evaluates; a dev session without a test server never does.
            return;
        }
        fetchDate = date;
        if (WallpaperState.dev) {
            runFetch();
            return;
        }
        // Metered connections are left alone (the flag is not exposed by Quickshell: one nmcli query per fetch, no polling).
        phase = "scheduled";
        meteredProc.running = true;
    }

    Process {
        id: meteredProc
        command: ["nmcli", "-t", "-g", "GENERAL.METERED", "device", "show"]
        stdout: StdioCollector {
            id: meteredOut
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // An unreadable answer (no nmcli, no NetworkManager) is not metered: the connectivity gate already passed.
            const metered = exitCode === 0 && /^yes/m.test(meteredOut.text);
            if (metered) {
                root.phase = "waiting";
                nextTimer.interval = Tokens.wallpaperOnlineMeteredRecheckMs;
                nextTimer.restart();
                return;
            }
            root.runFetch();
        }
        // qmllint enable signal-handler-parameters
    }

    function runFetch(): void {
        const args = WallpaperConfig.fetchArgs(WallpaperState.tool, root.provider, fetchDate, root.outDir, root.lang, root.devBaseUrl);
        if (args === null) {
            console.warn("wallpaper online: no valid fetch command");
            return;
        }
        fetchCount++;
        phase = "fetching";
        fetchOut = "";
        fetchExit = -2;
        gotOut = false;
        gotExit = false;
        fetchTimeout.restart();
        fetchProc.command = args;
        fetchProc.running = true;
    }

    property string fetchOut: ""
    property int fetchExit: -2
    property bool gotOut: false
    property bool gotExit: false
    property bool fetchTimedOut: false

    function fetchDone(): void {
        if (!(gotOut && gotExit))
            return;
        joinTimer.stop();
        fetchTimeout.stop();
        let o = null;
        try {
            o = JSON.parse(fetchOut);
        } catch (e) {
            o = null;
        }
        const now = Date.now();
        let outcome = "failed";
        if (o && o.ok === true && fetchExit === 0) {
            outcome = "ok";
            lastFailure = "";
            adopt(o);
        } else if (o && typeof o.code === "number" && WallpaperConfig.onlineSkips(o.code)) {
            outcome = "skipped";
            lastFailure = WallpaperConfig.reasonOf(o.code);
        } else {
            lastFailure = fetchTimedOut ? "timeout" : o && typeof o.code === "number" ? WallpaperConfig.reasonOf(o.code) : "failed";
        }
        if (outcome !== "ok")
            console.warn("wallpaper online: fetch " + fetchDate + " " + outcome + (o && o.reason ? " (" + o.reason + ")" : "") + (fetchTimedOut ? " (timed out)" : ""));
        fetchTimedOut = false;
        saveState(WallpaperConfig.onlineAfter(sched, now, fetchDate, outcome));
        phase = "scheduled";
        publish();
        evaluate();
    }

    Process {
        id: fetchProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.fetchOut = text;
                root.gotOut = true;
                root.fetchDone();
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            root.fetchExit = exitCode;
            root.gotExit = true;
            // The output may never arrive when the process could not start at all.
            joinTimer.start();
            root.fetchDone();
        }
        // qmllint enable signal-handler-parameters
    }

    Timer {
        id: joinTimer
        interval: 150
        onTriggered: {
            root.gotOut = true;
            root.fetchDone();
        }
    }

    Timer {
        id: fetchTimeout
        interval: Tokens.wallpaperFetchTimeoutMs
        onTriggered: {
            root.fetchTimedOut = true;
            if (fetchProc.running)
                fetchProc.signal(9);
        }
    }
}
