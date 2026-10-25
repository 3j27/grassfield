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
    // Another provider: its own cache and accounting. What was cached for the previous one is not shown for this one.
    onProviderChanged: {
        entry = null;
        entryLoaded = false;
        if (wanted)
            loadLatest();
    }
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
        latestProc.didStart = false;
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
            // Never an older day's picture over a newer one; the same day's picture again only when it was fetched again.
            const newer = !root.entry || o.date > root.entry.date || (o.date === root.entry.date && root.entry.fetchedAt !== o.fetchedAt);
            if (newer)
                root.entry = o;
        }
    }

    Process {
        id: latestProc
        environment: WallpaperState.toolEnv
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
        property bool didStart: false
        onStarted: didStart = true
        // A helper that cannot start sends no `exited`: the scheduler would wait for the cache for ever.
        onRunningChanged: {
            if (!running && !didStart && !root.entryLoaded) {
                console.warn("wallpaper online: could not start the helper to read the cache");
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
        const now = clock();
        const r = WallpaperConfig.onlineSchedule(sched, now, entry !== null, devOffsetMs !== 0 ? 0 : Math.random(), provider);
        if (r.state.slotDate !== sched.slotDate || r.state.slotAt !== sched.slotAt || r.state.provider !== sched.provider)
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
    // The provider of the fetch under way (a change of provider in Settings does not redirect a running fetch).
    property string fetchProvider: "commons"

    // Dev only, and only with the loopback test server: the scheduler's clock runs this many hours ahead (the visual test cannot
    // wait for a new UTC day). The date, the day's slot (at 00:10 while shifted), the backoff and the fetch all follow it, so the
    // test drives the real accounting. A restart of the shell resets it.
    property real devOffsetMs: 0

    function clock(): real {
        return Date.now() + devOffsetMs;
    }

    function devClock(hours: real): string {
        if (!WallpaperState.dev || devBaseUrl === "")
            return "refused";
        devOffsetMs = Math.max(0, Math.min(24 * 400, hours)) * 3600000;
        evaluate();
        return "ok";
    }

    // Dev only: what the scheduler knows, one line of JSON.
    function devStatus(): string {
        return WallpaperState.dev ? JSON.stringify({phase: phase, failure: lastFailure, fetchCount: fetchCount, sched: sched, entry: entry ? entry.date : ""}) : "refused";
    }

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
        fetchProvider = provider;
        if (WallpaperState.dev) {
            runFetch();
            return;
        }
        // Metered connections are left alone (the flag is not exposed by Quickshell: one nmcli query per fetch, no polling).
        phase = "scheduled";
        meteredHandled = false;
        meteredProc.didStart = false;
        meteredProc.command = root.meteredCommand;
        meteredTimeout.interval = root.meteredTimeoutMs;
        meteredTimeout.restart();
        meteredProc.running = true;
    }

    // Test seams (a test names a command that does not exist, or one that hangs, and a short timeout); the defaults are the
    // production values.
    property var meteredCommand: ["nmcli", "-t", "-g", "GENERAL.METERED", "device", "show"]
    property int meteredTimeoutMs: Tokens.wallpaperMeteredTimeoutMs
    property var fetchCommandOverride: []
    property int fetchTimeoutMs: Tokens.wallpaperFetchTimeoutMs

    // Every way the nmcli query can end (an answer, a start failure, a timeout) lands here once.
    property bool meteredHandled: true

    function meteredResolved(metered: bool): void {
        if (meteredHandled)
            return;
        meteredHandled = true;
        meteredTimeout.stop();
        if (metered) {
            phase = "waiting";
            nextTimer.interval = Tokens.wallpaperOnlineMeteredRecheckMs;
            nextTimer.restart();
            return;
        }
        runFetch();
    }

    Process {
        id: meteredProc
        // Set by started: a run that ends without it never started (see onRunningChanged).
        property bool didStart: false
        stdout: StdioCollector {
            id: meteredOut
        }
        onStarted: didStart = true
        // Quickshell sends no `exited` when a start fails, only running going back to false without a `started`. An
        // unreadable answer (no nmcli, no NetworkManager, a hang) is not metered: the connectivity gate already passed.
        onRunningChanged: {
            if (!running && !didStart) {
                console.warn("wallpaper online: could not start nmcli; the connection counts as not metered");
                root.meteredResolved(false);
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => root.meteredResolved(exitCode === 0 && /^yes/m.test(meteredOut.text))
        // qmllint enable signal-handler-parameters
    }

    Timer {
        id: meteredTimeout
        onTriggered: {
            console.warn("wallpaper online: nmcli did not answer; the connection counts as not metered");
            if (meteredProc.running)
                meteredProc.signal(9);
            root.meteredResolved(false);
        }
    }

    function runFetch(): void {
        const args = root.fetchCommandOverride.length > 0 ? root.fetchCommandOverride : WallpaperConfig.fetchArgs(WallpaperState.tool, root.fetchProvider, fetchDate, WallpaperState.cacheDir + "/online/" + root.fetchProvider, root.lang, root.devBaseUrl);
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
        fetchProc.didStart = false;
        fetchTimeout.interval = root.fetchTimeoutMs;
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
        // One accounting per run: a late stream end after a start failure must not count again.
        gotOut = false;
        gotExit = false;
        joinTimer.stop();
        fetchTimeout.stop();
        let o = null;
        try {
            o = JSON.parse(fetchOut);
        } catch (e) {
            o = null;
        }
        const now = clock();
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
        else
            console.info("wallpaper online: fetched " + fetchDate + (o.cached ? " (already cached)" : ""));
        fetchTimedOut = false;
        saveState(WallpaperConfig.onlineAfter(sched, now, fetchDate, outcome, fetchProvider));
        phase = "scheduled";
        publish();
        evaluate();
    }

    Process {
        id: fetchProc
        environment: WallpaperState.toolEnv
        // Set by started: a run that ends without it never started (see onRunningChanged).
        property bool didStart: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.fetchOut = text;
                root.gotOut = true;
                root.fetchDone();
            }
        }
        onStarted: didStart = true
        // Quickshell sends no `exited` when a start fails, only running going back to false without a `started`: the fetch
        // fails (backoff) instead of staying "fetching" for ever.
        onRunningChanged: {
            if (!running && !didStart) {
                console.warn("wallpaper online: could not start the helper");
                root.fetchExit = 127;
                root.gotOut = true;
                root.gotExit = true;
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
        onTriggered: {
            root.fetchTimedOut = true;
            if (fetchProc.running)
                fetchProc.signal(9);
        }
    }
}
